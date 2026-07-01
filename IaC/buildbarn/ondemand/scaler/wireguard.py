"""
WireGuard hub management for AWS (off-Hetzner) ondemand workers.

Why this exists
===============
Hetzner workers live ON the central's private Hetzner Cloud network, so they
dial the scheduler (`:8983`) and frontend/CAS (`:8980`) straight at the
central's private IP (see worker/config/common.libsonnet). AWS Graviton
fallback workers are NOT on that network, so they reach those same private
ports over a WireGuard tunnel instead:

  * The central host runs a WireGuard hub interface (`wg0`, default
    10.99.0.1/16, UDP :51820 on the Floating IP). Stand it up once with
    scripts/setup-wireguard-hub.sh.
  * Each AWS worker is a spoke. The scaler generates a fresh keypair per
    spawn, registers the worker's PUBLIC key on the hub as a peer
    (`wg set wg0 peer <pub> allowed-ips <tunnel-ip>/32`), and bakes the
    PRIVATE key + tunnel IP into the worker's cloud-init.
  * The worker's `AllowedIPs` routes the central's *Hetzner private IP*
    (and optionally repo.ci.percona.com) THROUGH the tunnel. So the worker
    config dials the exact same `__CENTRAL_PRIVATE_IP__` a Hetzner worker
    would — no worker.jsonnet / common.libsonnet change, no extra port
    binding on the central. Packets arrive on wg0 destined for the central's
    own local private IP and are delivered locally; replies route back to
    the worker's 10.99.x tunnel IP via wg0.

Lifecycle coupling
==================
A peer is added BEFORE the instance boots (the worker brings its tunnel up in
cloud-init and immediately needs the hub to accept it) and removed AFTER the
instance is terminated on scale-down. Peer state on the hub is therefore a
mirror of the AWS-managed-VM set; `reconcile_peers()` prunes orphans so a
scaler restart (or a worker that died without a clean reap) can't leak peers.

The scaler container runs with `network_mode: host` + `cap_add: NET_ADMIN`
and ships `wireguard-tools`, so `wg`/`wg-quick` operate on the host's wg0
directly (see compose/docker-compose.yml + scaler/Dockerfile).
"""
from __future__ import annotations

import ipaddress
import logging
import subprocess
from dataclasses import dataclass

log = logging.getLogger("scaler.wireguard")


@dataclass
class WireguardCfg:
    """Hub-side WireGuard parameters, sourced from GlobalCfg / .env.

    All of these describe the HUB (the central). The per-worker private key
    and tunnel IP are generated at spawn time, not stored here.
    """
    enabled: bool
    iface: str            # host interface name, e.g. "wg0"
    hub_pubkey: str       # central's WireGuard public key (worker peers with this)
    hub_endpoint: str     # "<public-ip-or-host>:51820" the worker dials
    cidr: str             # tunnel address pool, e.g. "10.99.0.0/16"
    hub_ip: str           # the hub's own tunnel address, e.g. "10.99.0.1" (reserved)
    # Comma-separated CIDRs the worker routes THROUGH the tunnel. Must include
    # the central's Hetzner private IP (so :8980/:8983 resolve over wg) and may
    # include repo.ci.percona.com's address if RBE build actions need it.
    allowed_ips: str


def gen_keypair() -> tuple[str, str]:
    """Return (private_key, public_key) using the wg CLI.

    Mirrors `wg genkey | tee priv | wg pubkey`. Raises CalledProcessError if
    wireguard-tools is missing — caller should surface that as a config error
    (the scaler image is supposed to ship it).
    """
    priv = subprocess.run(
        ["wg", "genkey"], capture_output=True, text=True, check=True
    ).stdout.strip()
    pub = subprocess.run(
        ["wg", "pubkey"], input=priv, capture_output=True, text=True, check=True
    ).stdout.strip()
    return priv, pub


def list_peer_pubkeys(iface: str) -> set[str]:
    """All peer public keys currently configured on the hub interface."""
    out = subprocess.run(
        ["wg", "show", iface, "peers"], capture_output=True, text=True, check=True
    ).stdout
    return {line.strip() for line in out.splitlines() if line.strip()}


def add_peer(iface: str, pubkey: str, tunnel_ip: str) -> None:
    """Register a worker as a hub peer, pinned to a single /32 tunnel IP.

    Idempotent: re-adding the same pubkey just re-asserts its allowed-ips.
    """
    subprocess.run(
        ["wg", "set", iface, "peer", pubkey, "allowed-ips", f"{tunnel_ip}/32"],
        capture_output=True, text=True, check=True,
    )
    log.info("wg: added peer %s → %s/32 on %s", pubkey[:12] + "…", tunnel_ip, iface)


def remove_peer(iface: str, pubkey: str) -> None:
    """Drop a worker peer from the hub. Idempotent — removing an unknown peer
    is a no-op that wg reports success for."""
    subprocess.run(
        ["wg", "set", iface, "peer", pubkey, "remove"],
        capture_output=True, text=True, check=True,
    )
    log.info("wg: removed peer %s from %s", pubkey[:12] + "…", iface)


def allocate_tunnel_ip(cidr: str, used: set[str], reserved: set[str]) -> str:
    """Lowest free host address in `cidr` not already in `used` or `reserved`.

    `used` are the tunnel IPs of live AWS workers (read back from their tags);
    `reserved` holds at least the hub's own address. We skip the network and
    broadcast addresses. Raises RuntimeError if the pool is exhausted — that
    should never happen with a /16 and max_total_nodes in the low hundreds,
    but failing loud beats silently colliding two workers on one IP.
    """
    net = ipaddress.ip_network(cidr, strict=False)
    taken = {ipaddress.ip_address(x) for x in (used | reserved)}
    for host in net.hosts():
        if host not in taken:
            return str(host)
    raise RuntimeError(f"WireGuard tunnel pool {cidr} exhausted ({len(taken)} in use)")


def reconcile_peers(iface: str, expected: dict[str, str]) -> None:
    """Make the hub's peer set match `expected` ({pubkey: tunnel_ip}).

    Adds peers we expect but the hub lacks (e.g. after a hub/scaler restart
    that lost runtime wg state), and removes peers the hub has but we no
    longer expect (orphans from workers that died without a clean reap).
    Called once per scaler tick after the managed-VM list is known.
    """
    have = list_peer_pubkeys(iface)
    want = set(expected)
    for pub in want - have:
        try:
            add_peer(iface, pub, expected[pub])
        except subprocess.CalledProcessError as e:
            log.warning("wg: failed to re-add peer %s: %s", pub[:12] + "…", e.stderr)
    for pub in have - want:
        try:
            remove_peer(iface, pub)
        except subprocess.CalledProcessError as e:
            log.warning("wg: failed to prune orphan peer %s: %s", pub[:12] + "…", e.stderr)
