"""
Cloud-provider abstraction for the bb-psmdb-ondemand scaler.

Originally the scaler talked only to Hetzner. AWS Graviton (arm64) workers
were added as a capacity FALLBACK for aarch64 pools — Hetzner's CAX inventory
in hel1/nbg1/fsn1 is frequently exhausted, leaving arm stages queued for hours
(see ../README.md §"aarch64 worker support" and §11.1). When a Hetzner spawn
for an aarch64 pool exhausts every region, the scaler retries the same pool on
AWS Graviton instead; those VMs reach the central over WireGuard (see
wireguard.py).

This module owns the two concrete providers behind a common `CloudProvider`
interface plus the shared `ManagedVM` view and label/tag conventions. The
scaler (scaler.py) owns the decision LOGIC (when to scale up/down, which
provider to prefer, WireGuard peer lifecycle); providers here own only the
mechanics of "list / create / delete a worker on this cloud".
"""
from __future__ import annotations

import dataclasses
import logging
import time
from datetime import datetime, timezone
from typing import TYPE_CHECKING, Protocol

from hcloud import Client as HcloudClient
from hcloud.images.domain import Image
from hcloud.locations.domain import Location
from hcloud.server_types.domain import ServerType
from hcloud.ssh_keys.domain import SSHKey
from hcloud.networks.domain import Network

if TYPE_CHECKING:                       # avoid a runtime import cycle with scaler.py
    from scaler import GlobalCfg, PoolCfg

log = logging.getLogger("scaler.providers")

# ---------------------------------------------------------------------------
# Labels / tags. Same KEYS across both clouds so `list_managed()` parses one
# shape. Hetzner stores them as server labels; AWS stores them as instance
# tags. Dots are legal in both. The `managed-by` key is the discriminator the
# scaler uses to re-discover its fleet on restart — anything without it is
# someone else's resource and is ignored.
# ---------------------------------------------------------------------------
LABEL_MANAGED = "psmdb.managed-by"
LABEL_MANAGED_VALUE = "bb-ondemand-scaler"
LABEL_POOL = "psmdb.pool"
LABEL_VERSION = "psmdb.version"
LABEL_SPAWNED = "psmdb.spawned-at"      # unix ts at spawn time
LABEL_WG_PUBKEY = "psmdb.wg-pubkey"     # AWS only: worker's WireGuard public key
LABEL_WG_IP = "psmdb.wg-ip"             # AWS only: worker's WireGuard tunnel IP

# RFC-1123 budget for the pool slug in a VM name; see scaler.py for the full
# rationale. Hetzner enforces it; for AWS it only feeds the Name tag, but we
# keep the same slug so a name means the same thing on both clouds.
_POOL_SLUG_BUDGET = 37


def sanitize_pool_slug(pool_name: str) -> str:
    """Return an RFC-1123-safe ≤37-char slug derived from a pool key."""
    slug = pool_name.lower().replace("_", "-")
    while "--" in slug:
        slug = slug.replace("--", "-")
    return slug[:_POOL_SLUG_BUDGET].rstrip("-")


@dataclasses.dataclass
class ManagedVM:
    """A worker the scaler owns, reconstructed from cloud labels/tags.

    Unified across providers: `id` is a string (Hetzner numeric id stringified,
    AWS instance id verbatim) and `provider` records which cloud to delete it
    on. `wg_pubkey` / `wg_ip` are populated for AWS workers only — the scaler
    uses them to reconcile and prune WireGuard hub peers.
    """
    id: str
    name: str
    pool: str
    version: str
    spawned_at: datetime
    status: str
    provider: str
    wg_pubkey: str | None = None
    wg_ip: str | None = None
    idle_since: datetime | None = None


class CloudProvider(Protocol):
    """The mechanics the scaler needs from any cloud backend."""

    name: str

    def list_managed(self) -> list[ManagedVM]: ...

    def create_worker(
        self,
        *,
        pool: "PoolCfg",
        global_: "GlobalCfg",
        user_data: str,
        name_suffix: str = "",
        extra_labels: dict[str, str] | None = None,
        instance_types: list[str] | None = None,
    ) -> str: ...

    def delete_worker(self, vm: ManagedVM) -> None: ...


def _worker_name(pool_name: str, name_suffix: str) -> str:
    ts = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    return f"bb-worker-{sanitize_pool_slug(pool_name)}-{ts}{name_suffix}"


def _base_labels(pool: "PoolCfg") -> dict[str, str]:
    return {
        LABEL_MANAGED: LABEL_MANAGED_VALUE,
        LABEL_POOL: pool.name,
        LABEL_VERSION: pool.psmdb_version,
        LABEL_SPAWNED: str(int(time.time())),
        "project": "psmdb-buildbarn",
        "role": "bb-worker",
    }


def _parse_spawned(raw: str | None) -> datetime:
    try:
        return datetime.fromtimestamp(int(raw or "0"), tz=timezone.utc)
    except (ValueError, TypeError):
        return datetime.now(timezone.utc)


# ---------------------------------------------------------------------------
# Hetzner — the primary provider (unchanged behaviour, now behind the interface).
# ---------------------------------------------------------------------------
class HetznerOps:
    """Thin wrapper over hcloud-python that encodes our labelling convention."""

    name = "hetzner"

    def __init__(self, token: str) -> None:
        if not token:
            raise RuntimeError("HCLOUD_TOKEN not set — scaler cannot talk to Hetzner")
        self.client = HcloudClient(token=token)

    def list_managed(self) -> list[ManagedVM]:
        servers = self.client.servers.get_all(
            label_selector=f"{LABEL_MANAGED}={LABEL_MANAGED_VALUE}"
        )
        out: list[ManagedVM] = []
        for s in servers:
            labels = s.labels or {}
            out.append(ManagedVM(
                id=str(s.id),
                name=s.name,
                pool=labels.get(LABEL_POOL, ""),
                version=labels.get(LABEL_VERSION, ""),
                spawned_at=_parse_spawned(labels.get(LABEL_SPAWNED)),
                status=s.status,
                provider=self.name,
            ))
        return out

    def create_worker(
        self,
        *,
        pool: "PoolCfg",
        global_: "GlobalCfg",
        user_data: str,
        name_suffix: str = "",
        extra_labels: dict[str, str] | None = None,
        instance_types: list[str] | None = None,   # AWS-only; ignored here
    ) -> str:
        """Create a Hetzner VM with region fallback. Returns the new server ID.

        Raises RuntimeError when EVERY region in the try-chain is exhausted —
        the scaler treats that exception as the trigger to fall back to AWS
        for aarch64 pools that have an `aws_instance_type` configured.
        """
        name = _worker_name(pool.name, name_suffix)
        labels = _base_labels(pool) | (extra_labels or {})
        ssh_keys = [SSHKey(id=kid) for kid in global_.ssh_key_ids]
        networks = [Network(id=global_.network_id)]

        last_err: Exception | None = None
        for region in global_.region_try_chain:
            try:
                resp = self.client.servers.create(
                    name=name,
                    server_type=ServerType(name=pool.server_type),
                    image=Image(name=global_.os_image),
                    location=Location(name=region),
                    ssh_keys=ssh_keys,
                    networks=networks,
                    user_data=user_data,
                    labels=labels,
                    start_after_create=True,
                )
                log.info(
                    "hetzner: spawned %s (id=%s) in %s, type=%s, pool=%s",
                    name, resp.server.id, region, pool.server_type, pool.name,
                )
                return str(resp.server.id)
            except Exception as e:  # noqa: BLE001
                last_err = e
                log.warning("hetzner: create in %s failed: %s — next region", region, e)
        raise RuntimeError(f"hetzner: all regions exhausted; last error: {last_err}")

    def delete_worker(self, vm: ManagedVM) -> None:
        log.info("hetzner: deleting %s (id=%s, pool=%s)", vm.name, vm.id, vm.pool)
        server = self.client.servers.get_by_id(int(vm.id))
        if server is not None:
            server.delete()


# ---------------------------------------------------------------------------
# AWS — the Graviton fallback provider.
# ---------------------------------------------------------------------------
class AwsOps:
    """EC2 wrapper for Graviton fallback workers.

    Deliberately narrow, mirroring the IAM shape Percona already uses for the
    percona-server GHA Hetzner-exhausted fallback role
    (terraform/iam-gha-percona-server-ec2-fallback.tf in percona-cd-platform):
    RunInstances / TerminateInstances / DescribeInstances, region-locked,
    mandatory cleanup tags. The instance gets NO instance profile — build code
    on it (including PR code) cannot reach the AWS API.

    Region, subnet, security groups and AMI come from GlobalCfg (sourced from
    .env). Credentials come from boto3's default chain — the scaler runs on
    Hetzner with no instance profile, so in practice that's a narrow IAM-user
    access key in the scaler's environment.
    """

    name = "aws"

    # EC2 user-data ceiling, applied to the gzip-compressed payload we ship.
    _USER_DATA_LIMIT = 16 * 1024

    # Error codes that mean "this (type, AZ) has no capacity right now" — try
    # the next instance type rather than giving up. Everything else (auth,
    # quota, malformed request) re-raises immediately.
    _CAPACITY_ERROR_CODES = frozenset({
        "InsufficientInstanceCapacity",
        "InsufficientHostCapacity",
        "SpotMaxPriceTooLow",
        "Unsupported",                       # type not offered in this AZ
        "InsufficientReservedInstanceCapacity",
    })

    def __init__(self, *, region: str) -> None:
        import boto3  # lazy: only needed when AWS fallback is configured
        self.region = region
        self.ec2 = boto3.client("ec2", region_name=region)
        self._root_dev_cache: dict[str, str] = {}

    def _root_device_name(self, ami_id: str) -> str:
        """Root device name for an AMI (e.g. '/dev/sda1' on Ubuntu), cached.
        Needed so BlockDeviceMappings overrides the RIGHT device's size."""
        if ami_id not in self._root_dev_cache:
            imgs = self.ec2.describe_images(ImageIds=[ami_id]).get("Images", [])
            # Ubuntu arm64 AMIs use /dev/sda1; fall back to it if absent.
            self._root_dev_cache[ami_id] = (imgs[0].get("RootDeviceName") if imgs else None) or "/dev/sda1"
        return self._root_dev_cache[ami_id]

    def list_managed(self) -> list[ManagedVM]:
        out: list[ManagedVM] = []
        paginator = self.ec2.get_paginator("describe_instances")
        pages = paginator.paginate(
            Filters=[
                {"Name": f"tag:{LABEL_MANAGED}", "Values": [LABEL_MANAGED_VALUE]},
                {"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]},
            ]
        )
        for page in pages:
            for res in page.get("Reservations", []):
                for inst in res.get("Instances", []):
                    tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
                    out.append(ManagedVM(
                        id=inst["InstanceId"],
                        name=tags.get("Name", inst["InstanceId"]),
                        pool=tags.get(LABEL_POOL, ""),
                        version=tags.get(LABEL_VERSION, ""),
                        spawned_at=_parse_spawned(tags.get(LABEL_SPAWNED)),
                        status=inst.get("State", {}).get("Name", "unknown"),
                        provider=self.name,
                        wg_pubkey=tags.get(LABEL_WG_PUBKEY),
                        wg_ip=tags.get(LABEL_WG_IP),
                    ))
        return out

    def create_worker(
        self,
        *,
        pool: "PoolCfg",
        global_: "GlobalCfg",
        user_data: str,
        name_suffix: str = "",
        extra_labels: dict[str, str] | None = None,
        instance_types: list[str] | None = None,
    ) -> str:
        from botocore.exceptions import ClientError

        types = list(instance_types or [])
        if not types:
            raise ValueError(f"pool '{pool.name}' AWS spawn: no instance types provided")
        name = _worker_name(pool.name, name_suffix)
        tags = _base_labels(pool) | (extra_labels or {}) | {"Name": name}
        # Mandatory cleanup tags so percona-dev-admin reaper Lambdas don't kill
        # the instance out from under an in-flight build (and DO reap it if the
        # scaler dies before the scale-down path runs).
        tags.setdefault("iit-billing-tag", global_.aws_billing_tag)
        tags.setdefault("PerconaKeep", "True")
        tag_specs = [{
            "ResourceType": "instance",
            "Tags": [{"Key": k, "Value": v} for k, v in tags.items()],
        }]

        # cloud-init auto-detects gzip magic and decompresses; gzipping keeps
        # us under EC2's 16 KB user-data limit (the worker stack is ~17 KB raw,
        # ~4 KB gzipped). botocore base64-encodes the bytes for the wire.
        import gzip
        payload = gzip.compress(user_data.encode("utf-8"))
        if len(payload) > self._USER_DATA_LIMIT:
            raise ValueError(
                f"pool '{pool.name}' AWS user-data is {len(payload)} bytes gzipped — "
                f"exceeds EC2's {self._USER_DATA_LIMIT} B limit; trim worker configs"
            )

        base_kwargs: dict = dict(
            ImageId=global_.aws_ami_id,
            MinCount=1,
            MaxCount=1,
            UserData=payload,
            SubnetId=global_.aws_subnet_id,
            SecurityGroupIds=global_.aws_security_group_ids,
            TagSpecifications=tag_specs,
            # Override the AMI's tiny default root (Ubuntu arm64 = 8 GB) — far
            # too small for the 32 GB swapfile + ~100 GB hardlinking cache +
            # runner image. Without this, cloud-init dies with ENOSPC and the
            # worker never registers.
            BlockDeviceMappings=[{
                "DeviceName": self._root_device_name(global_.aws_ami_id),
                "Ebs": {
                    "VolumeSize": global_.aws_root_volume_gb,
                    "VolumeType": "gp3",
                    "DeleteOnTermination": True,
                },
            }],
            # Self-destruct safety net: even if the scaler never issues a
            # TerminateInstances, a halt inside the VM terminates it.
            InstanceInitiatedShutdownBehavior="terminate",
            MetadataOptions={"HttpTokens": "required", "HttpEndpoint": "enabled"},
        )
        if global_.aws_key_name:
            base_kwargs["KeyName"] = global_.aws_key_name
        if global_.aws_use_spot:
            # one-time spot (no relaunch by AWS) — the scaler owns replacement.
            base_kwargs["InstanceMarketOptions"] = {
                "MarketType": "spot",
                "SpotOptions": {"SpotInstanceType": "one-time"},
            }

        # Spot-resilience: walk the diversified type list, moving to the next
        # type whenever AWS reports no capacity for the current one. Same shape
        # as HetznerOps' region try-chain — and like it, raises RuntimeError
        # only when EVERY candidate is exhausted (the scaler logs it and retries
        # next tick).
        last_err: Exception | None = None
        for itype in types:
            try:
                resp = self.ec2.run_instances(InstanceType=itype, **base_kwargs)
                iid = resp["Instances"][0]["InstanceId"]
                log.info(
                    "aws: spawned %s (id=%s) in %s, type=%s, spot=%s, pool=%s",
                    name, iid, self.region, itype, global_.aws_use_spot, pool.name,
                )
                return iid
            except ClientError as e:
                code = e.response.get("Error", {}).get("Code", "")
                if code in self._CAPACITY_ERROR_CODES:
                    last_err = e
                    log.warning(
                        "aws: %s for type=%s (spot=%s) — trying next type",
                        code, itype, global_.aws_use_spot,
                    )
                    continue
                raise   # auth / quota / malformed → not a capacity problem
        raise RuntimeError(
            f"aws: all {len(types)} instance types exhausted for pool={pool.name}; "
            f"last error: {last_err}"
        )

    def delete_worker(self, vm: ManagedVM) -> None:
        log.info("aws: terminating %s (id=%s, pool=%s)", vm.name, vm.id, vm.pool)
        self.ec2.terminate_instances(InstanceIds=[vm.id])
