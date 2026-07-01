"""
Minimal unit tests for the scaler's AWS-fallback decision logic.

Run (no extra deps — stdlib unittest):
    cd ondemand/scaler && python3 -m unittest test_scaler -v

We stub `hcloud` (providers.py imports it at module top) so the tests run
without the SDK installed. boto3 is imported lazily inside AwsOps and is never
reached here — the tests use FAKE providers, not the real clouds.
"""
import sys
import types
import unittest
from datetime import datetime, timezone


# --- stub hcloud + submodules so `import providers` works offline -----------
def _stub(name):
    m = types.ModuleType(name)
    sys.modules.setdefault(name, m)
    return m


_stub("hcloud").Client = object
for _sub, _attr in [
    ("hcloud.images.domain", "Image"),
    ("hcloud.locations.domain", "Location"),
    ("hcloud.server_types.domain", "ServerType"),
    ("hcloud.ssh_keys.domain", "SSHKey"),
    ("hcloud.networks.domain", "Network"),
]:
    setattr(_stub(_sub), _attr, object)

import scaler  # noqa: E402
import wireguard  # noqa: E402
from providers import LABEL_WG_IP, LABEL_WG_PUBKEY, ManagedVM  # noqa: E402


# --- builders ---------------------------------------------------------------
RUNNER = "docker.io/perconalab/psmdb-rbe:ubuntu-noble-master-deadbeef"


def make_global(**over):
    base = dict(
        scheduler_state_grpc="127.0.0.1:8984",
        scheduler_public_url="http://central:7984",
        scheduler_private_ip="10.30.246.5",
        ssh_key_ids=[1], network_id=2, os_image="debian-13",
        region_try_chain=["hel1", "nbg1", "fsn1"],
        max_total_nodes=150, max_cost_per_hour_eur=2.0,
        poll_interval_seconds=30, scale_down_idle_seconds=600, scale_up_threshold=1,
        aws_enabled=True, aws_region="eu-central-1",
        aws_subnet_id="subnet-1", aws_security_group_ids=["sg-1"], aws_ami_id="ami-1",
    )
    base.update(over)
    return scaler.GlobalCfg(**base)


def make_pool(name="ubuntu-noble-aarch64__vmaster__deadbeef", **over):
    base = dict(
        name=name, runner_image=RUNNER, bazel_pool_value="aarch64",
        psmdb_version="master", server_type="cax31", concurrency=12,
        min_nodes=0, max_nodes=5, provider="hetzner",
        aws_fallback=True,                 # opted into Graviton fallback
        aws_instance_types=[],             # inherit global list
    )
    base.update(over)
    return scaler.PoolCfg(**base)


def make_queue(pool, queued=12, executing=0, idle=0, workers_total=0):
    return scaler.PlatformQueue(
        instance_prefix="hardlinking",
        platform_props={"container-image": pool.container_image, "Pool": pool.bazel_pool_value},
        queued=queued, executing=executing, idle=idle, workers_total=workers_total,
    )


def make_wg(enabled=True):
    return wireguard.WireguardCfg(
        enabled=enabled, iface="wg0", hub_pubkey="HUB=", hub_endpoint="1.2.3.4:51820",
        cidr="10.99.0.0/16", hub_ip="10.99.0.1", allowed_ips="10.30.246.5/32",
    )


class FakeProvider:
    """Records create/delete; optionally raises RuntimeError on create to
    simulate Hetzner region exhaustion."""

    def __init__(self, name, *, raise_on_create=False, existing=None):
        self.name = name
        self.raise_on_create = raise_on_create
        self.existing = existing or []
        self.created = []
        self.deleted = []

    def list_managed(self):
        return list(self.existing)

    def create_worker(self, *, pool, global_, user_data, name_suffix="",
                       extra_labels=None, instance_types=None):
        if self.raise_on_create:
            raise RuntimeError(f"{self.name}: all regions exhausted")
        self.created.append((pool.name, dict(extra_labels or {}), list(instance_types or [])))
        return f"{self.name}-id-{len(self.created)}"

    def delete_worker(self, vm):
        self.deleted.append(vm.id)


# ---------------------------------------------------------------------------
class TestTunnelIPAllocation(unittest.TestCase):
    def test_lowest_free_skips_used_and_reserved(self):
        ip = wireguard.allocate_tunnel_ip("10.99.0.0/16", used={"10.99.0.2", "10.99.0.4"},
                                          reserved={"10.99.0.1"})
        self.assertEqual(ip, "10.99.0.3")

    def test_raises_on_exhaustion(self):
        with self.assertRaises(RuntimeError):
            wireguard.allocate_tunnel_ip("10.99.0.0/30", used={"10.99.0.1", "10.99.0.2"},
                                         reserved=set())


class TestReconcilePeers(unittest.TestCase):
    def setUp(self):
        self._orig = (wireguard.list_peer_pubkeys, wireguard.add_peer, wireguard.remove_peer)
        self.added, self.removed = [], []
        wireguard.add_peer = lambda iface, pub, ip: self.added.append((pub, ip))
        wireguard.remove_peer = lambda iface, pub: self.removed.append(pub)

    def tearDown(self):
        wireguard.list_peer_pubkeys, wireguard.add_peer, wireguard.remove_peer = self._orig

    def test_adds_missing_and_prunes_orphans(self):
        # Hub currently has peers {KEEP, ORPHAN}; we expect {KEEP, NEW}.
        wireguard.list_peer_pubkeys = lambda iface: {"KEEP", "ORPHAN"}
        wireguard.reconcile_peers("wg0", {"KEEP": "10.99.0.2", "NEW": "10.99.0.3"})
        self.assertEqual(self.added, [("NEW", "10.99.0.3")])
        self.assertEqual(self.removed, ["ORPHAN"])


class TestFallbackEligibility(unittest.TestCase):
    def test_eligible_when_all_set(self):
        cfg = scaler.Cfg(global_=make_global(), pools={})
        self.assertTrue(scaler._pool_aws_fallback_ok(
            make_pool(), cfg, {"hetzner": object(), "aws": object()}, make_wg()))

    def test_not_eligible_without_aws_fallback(self):
        cfg = scaler.Cfg(global_=make_global(), pools={})
        self.assertFalse(scaler._pool_aws_fallback_ok(
            make_pool(aws_fallback=False), cfg, {"hetzner": object(), "aws": object()}, make_wg()))

    def test_fallback_all_aarch64_covers_unflagged_pools(self):
        cfg = scaler.Cfg(global_=make_global(aws_fallback_all_aarch64=True), pools={})
        providers = {"hetzner": object(), "aws": object()}
        # aarch64 pool WITHOUT per-pool aws_fallback → eligible via global flag
        self.assertTrue(scaler._pool_aws_fallback_ok(
            make_pool(aws_fallback=False, bazel_pool_value="aarch64"), cfg, providers, make_wg()))
        # x86_64 pool → never eligible (can't run x86 on Graviton)
        self.assertFalse(scaler._pool_aws_fallback_ok(
            make_pool(aws_fallback=False, bazel_pool_value="x86_64", server_type="cpx42"),
            cfg, providers, make_wg()))

    def test_effective_types_prefers_pool_override(self):
        cfg = scaler.Cfg(global_=make_global(), pools={})
        self.assertEqual(scaler._effective_instance_types(make_pool(), cfg),
                         cfg.global_.aws_instance_types)             # inherit global
        self.assertEqual(scaler._effective_instance_types(
            make_pool(aws_instance_types=["m7g.4xlarge"]), cfg), ["m7g.4xlarge"])  # override

    def test_not_eligible_when_wg_disabled(self):
        cfg = scaler.Cfg(global_=make_global(), pools={})
        self.assertFalse(scaler._pool_aws_fallback_ok(
            make_pool(), cfg, {"hetzner": object(), "aws": object()}, make_wg(enabled=False)))


class TestHetznerExhaustionFallsBackToAws(unittest.TestCase):
    def setUp(self):
        self._save = {k: getattr(scaler, k) for k in
                      ("DRY_RUN", "list_platform_queues", "render_user_data", "render_aws_user_data")}
        self._wg = (wireguard.reconcile_peers, wireguard.gen_keypair,
                    wireguard.add_peer, wireguard.remove_peer)
        scaler.DRY_RUN = False
        scaler.render_user_data = lambda **kw: "dummy"
        scaler.render_aws_user_data = lambda **kw: "dummy"
        wireguard.reconcile_peers = lambda *a, **k: None
        wireguard.gen_keypair = lambda: ("PRIV=", "PUBKEY=")
        self.added = []
        wireguard.add_peer = lambda iface, pub, ip: self.added.append((pub, ip))
        wireguard.remove_peer = lambda iface, pub: None

    def tearDown(self):
        for k, v in self._save.items():
            setattr(scaler, k, v)
        (wireguard.reconcile_peers, wireguard.gen_keypair,
         wireguard.add_peer, wireguard.remove_peer) = self._wg

    def test_fallback(self):
        pool = make_pool()
        cfg = scaler.Cfg(global_=make_global(), pools={pool.name: pool})
        scaler.list_platform_queues = lambda ep: [make_queue(pool, queued=12)]
        hetzner = FakeProvider("hetzner", raise_on_create=True)
        aws = FakeProvider("aws")
        providers = {"hetzner": hetzner, "aws": aws}

        scaler.iteration(cfg, providers, make_wg(), {})

        # Hetzner was tried (and raised); AWS picked up the spawn; a wg peer
        # was registered with the worker's pubkey + a tunnel IP.
        self.assertEqual(len(aws.created), 1, "expected one AWS fallback spawn")
        poolname, labels, types = aws.created[0]
        self.assertEqual(poolname, pool.name)
        self.assertEqual(labels.get(LABEL_WG_PUBKEY), "PUBKEY=")
        self.assertIn(LABEL_WG_IP, labels)
        self.assertEqual(types, cfg.global_.aws_instance_types)   # diversified pool passed through
        self.assertEqual(self.added, [("PUBKEY=", labels[LABEL_WG_IP])])

    def test_no_fallback_when_pool_ineligible(self):
        pool = make_pool(aws_fallback=False)   # not opted in → no fallback
        cfg = scaler.Cfg(global_=make_global(), pools={pool.name: pool})
        scaler.list_platform_queues = lambda ep: [make_queue(pool, queued=12)]
        hetzner = FakeProvider("hetzner", raise_on_create=True)
        aws = FakeProvider("aws")
        scaler.iteration(cfg, {"hetzner": hetzner, "aws": aws}, make_wg(), {})
        self.assertEqual(aws.created, [], "ineligible pool must not spawn on AWS")


class TestScaleDownDispatchesByProvider(unittest.TestCase):
    def setUp(self):
        self._save = {k: getattr(scaler, k) for k in ("DRY_RUN", "list_platform_queues")}
        self._wg = (wireguard.reconcile_peers, wireguard.remove_peer)
        scaler.DRY_RUN = False
        wireguard.reconcile_peers = lambda *a, **k: None
        self.removed_peers = []
        wireguard.remove_peer = lambda iface, pub: self.removed_peers.append(pub)

    def tearDown(self):
        for k, v in self._save.items():
            setattr(scaler, k, v)
        wireguard.reconcile_peers, wireguard.remove_peer = self._wg

    def test_idle_aws_worker_deleted_and_peer_removed(self):
        pool = make_pool(min_nodes=0)
        cfg = scaler.Cfg(global_=make_global(), pools={pool.name: pool})
        # No queue for the pool → idle. Pre-age the idle tracker past threshold.
        scaler.list_platform_queues = lambda ep: []
        vm = ManagedVM(id="i-aws1", name="bb-worker-aws", pool=pool.name, version="master",
                       spawned_at=datetime.now(timezone.utc), status="running",
                       provider="aws", wg_pubkey="PUBKEY=", wg_ip="10.99.0.2")
        aws = FakeProvider("aws", existing=[vm])
        old = datetime(2000, 1, 1, tzinfo=timezone.utc)
        scaler.iteration(cfg, {"hetzner": FakeProvider("hetzner"), "aws": aws},
                         make_wg(), {vm.name: old})
        self.assertEqual(aws.deleted, ["i-aws1"])
        self.assertEqual(self.removed_peers, ["PUBKEY="])


if __name__ == "__main__":
    unittest.main()
