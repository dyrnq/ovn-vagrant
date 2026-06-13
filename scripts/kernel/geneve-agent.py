#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["httpx"]
# ///
"""
geneve-agent — Pure Linux kernel Geneve overlay daemon (like flanneld).

No OVS. No OVN. Just Linux bridge + kernel Geneve + etcd.

Architecture (1:1 with flannel):
  etcd           →  etcd (same, v3 REST API)
  flanneld       →  geneve-agent.py (this)
  cni0           →  br-overlay (Linux bridge, .1 gateway)
  flannel.1      →  geneve-$PEER (kernel Geneve device, one per peer)
  ip route       →  ip route (host routing, not bridge)

Usage:
    sudo uv run geneve-agent.py
    sudo uv run geneve-agent.py --etcd-host 192.168.200.11
"""

import argparse
import base64
import json
import logging
import os
import re
import signal
import subprocess
import sys
import threading
import time

import httpx

# ── Defaults ────────────────────────────────────────────────

DEFAULTS = {
    "ETCD_HOST":      "192.168.200.11",
    "ETCD_PORT":      2379,
    "ETCD_PREFIX":    "/geneve/peers/",
    "ALLOC_PREFIX":   "/geneve/allocations/",
    "MGMT_NET":       "192.168.200.0/24",
    "OVERLAY_PREFIX": "172.16",
    "OVERLAY_MASK":   "24",
    "BRIDGE_NAME":    "br-overlay",
    "LEASE_TTL":      30,
}

log = logging.getLogger("geneve-agent")

# ── Helpers ─────────────────────────────────────────────────

def run(cmd, check=True):
    log.debug("exec: %s", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        log.warning("cmd failed [%d]: %s  stderr=%s",
                     r.returncode, " ".join(cmd), r.stderr.strip())
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def b64e(s):
    return base64.b64encode(s.encode()).decode()


def b64d(s):
    return base64.b64decode(s).decode()


def gen_mac():
    import random
    b = [0x52, 0x54, random.randint(0, 255), random.randint(0, 255),
         random.randint(0, 255), random.randint(0, 255)]
    return ":".join(f"{x:02x}" for x in b)


def detect_local_ip(mgmt_net):
    net_prefix = mgmt_net.rsplit(".", 1)[0]
    rc, out, _ = run(["ip", "-4", "-o", "addr", "show", "scope", "global"], check=False)
    if rc != 0:
        return None
    for line in out.splitlines():
        m = re.search(r'inet (\d+\.\d+\.\d+\.\d+)', line)
        if m and m.group(1).startswith(net_prefix):
            return m.group(1)
    return None


def cfg(args):
    c = dict(DEFAULTS)
    for k in DEFAULTS:
        env = os.environ.get(f"GENEVE_{k}")
        if env:
            c[k] = env
    if args.etcd_host:
        c["ETCD_HOST"] = args.etcd_host
    if args.etcd_port:
        c["ETCD_PORT"] = args.etcd_port
    if args.mgmt_net:
        c["MGMT_NET"] = args.mgmt_net
    if args.bridge:
        c["BRIDGE_NAME"] = args.bridge
    if args.interval:
        c["LEASE_TTL"] = args.interval
    c["ETCD_PORT"] = int(c["ETCD_PORT"])
    c["LEASE_TTL"] = int(c["LEASE_TTL"])
    c["PREFIX_LEN"] = int(c["OVERLAY_MASK"])
    c["ETCD_URL"] = f"http://{c['ETCD_HOST']}:{c['ETCD_PORT']}"
    return c


# ── etcd v3 REST API ────────────────────────────────────────

class EtcdClient:
    def __init__(self, url):
        self.url = url
        self.client = httpx.Client(base_url=url, timeout=10)
        self.lease_id = None

    def grant_lease(self, ttl):
        r = self.client.post("/v3/lease/grant", json={"TTL": ttl})
        r.raise_for_status()
        self.lease_id = r.json()["ID"]
        return self.lease_id

    def keepalive(self):
        """Refresh lease. Returns True on success, False if etcd unreachable."""
        if not self.lease_id:
            return False
        try:
            r = self.client.post("/v3/lease/keepalive", json={"ID": self.lease_id})
            r.raise_for_status()
            return True
        except Exception as e:
            log.warning("lease keepalive failed: %s", e)
            return False

    def put(self, key, value, lease_id=None):
        payload = {"key": b64e(key), "value": b64e(value)}
        if lease_id:
            payload["lease"] = str(lease_id)
        r = self.client.post("/v3/kv/put", json=payload)
        r.raise_for_status()

    def get(self, key):
        r = self.client.post("/v3/kv/range", json={"key": b64e(key)})
        r.raise_for_status()
        kvs = r.json().get("kvs", [])
        return b64d(kvs[0]["value"]) if kvs else None

    def get_prefix(self, prefix):
        payload = {"key": b64e(prefix), "range_end": b64e(prefix + "\xff")}
        r = self.client.post("/v3/kv/range", json=payload)
        r.raise_for_status()
        result = {}
        for kv in r.json().get("kvs", []):
            key = b64d(kv["key"])
            value = b64d(kv["value"])
            name = key.replace(prefix, "")
            result[name] = value
        return result

    def delete(self, key):
        self.client.post("/v3/kv/deleterange", json={"key": b64e(key)})

    def watch_prefix(self, prefix):
        payload = {"create_request": {"key": b64e(prefix), "range_end": b64e(prefix + "\xff")}}
        with self.client.stream("POST", "/v3/watch", json=payload) as r:
            for line in r.iter_lines():
                if not line:
                    continue
                try:
                    event = json.loads(line)
                    for ev in event.get("events", []):
                        kv = ev.get("kv", {})
                        key = b64d(kv.get("key", ""))
                        value = b64d(kv.get("value", ""))
                        if ev.get("type") == "DELETE":
                            yield "delete", key, None
                        else:
                            yield "put", key, value
                except (json.JSONDecodeError, KeyError):
                    continue

    def close(self):
        self.client.close()


# ── Linux bridge + Geneve management ────────────────────────

def ensure_bridge(bridge_name, gw_cidr):
    """Create Linux bridge with gateway IP."""
    rc, _, _ = run(["ip", "link", "show", bridge_name], check=False)
    if rc != 0:
        run(["ip", "link", "add", bridge_name, "type", "bridge"])
        run(["ip", "link", "set", bridge_name, "up"])
        log.info("created bridge %s", bridge_name)

    # Assign gateway IP if not present
    rc, out, _ = run(["ip", "-4", "-o", "addr", "show", "dev", bridge_name], check=False)
    gw_ip = gw_cidr.split("/")[0]
    if gw_ip not in out:
        run(["ip", "addr", "add", gw_cidr, "dev", bridge_name], check=False)

    # Disable ICMP redirect on bridge
    run(["sysctl", "-w", f"net.ipv4.conf.{bridge_name}.send_redirects=0"], check=False)

    log.info("bridge %s = %s", bridge_name, gw_cidr)


def geneve_dev_name(peer_name):
    return f"geneve-{peer_name}"


def ensure_geneve_bridge(dev, remote_ip, bridge_name):
    """Create Geneve device and attach to bridge."""
    rc, _, _ = run(["ip", "link", "show", dev], check=False)
    if rc != 0:
        run(["ip", "link", "add", dev, "type", "geneve",
             "remote", remote_ip, "id", "1"])
        run(["ip", "link", "set", dev, "master", bridge_name])
        run(["ip", "link", "set", dev, "up"])
        log.info("created geneve %s → %s (bridge %s)", dev, remote_ip, bridge_name)
    return True


def remove_geneve_bridge(dev):
    rc, _, _ = run(["ip", "link", "del", dev], check=False)
    if rc == 0:
        log.info("removed geneve %s", dev)


def add_peer(name, info, c):
    """Create Geneve tunnel to peer and attach to bridge."""
    dev = geneve_dev_name(name)
    ensure_geneve_bridge(dev, info["mgmt_ip"], c["BRIDGE_NAME"])

    # Host route for remote subnet via bridge (for host-initiated traffic)
    peer_id = info["gw_ip"].rsplit(".", 1)[0].split(".")[-1]
    subnet = f"{c['OVERLAY_PREFIX']}.{peer_id}.0/{c['PREFIX_LEN']}"
    run(["ip", "route", "replace", subnet, "dev", c["BRIDGE_NAME"]], check=False)
    log.info("route %s via %s", subnet, c["BRIDGE_NAME"])


def remove_peer(name, c):
    """Remove Geneve tunnel."""
    dev = geneve_dev_name(name)
    remove_geneve_bridge(dev)
    m = re.search(r'(\d+)$', name)
    if m:
        subnet = f"{c['OVERLAY_PREFIX']}.{m.group(1)}.0/{c['PREFIX_LEN']}"
        run(["ip", "route", "del", subnet], check=False)



# ── Allocation with conflict detection ──────────────────────

def _allocate_id(etcd, c, local_ip, alloc_key, hostname):
    """Allocate host_id with conflict detection.
    
    Scans existing allocations to avoid ID collision.
    """
    candidate_id = int(local_ip.rsplit(".", 1)[1])
    candidate_gw = f"{c['OVERLAY_PREFIX']}.{candidate_id}.1"

    # Scan all existing allocations
    existing = etcd.get_prefix(c["ALLOC_PREFIX"])
    used_ids = {}
    for name, val in existing.items():
        if name == hostname:
            continue
        try:
            alloc = json.loads(val)
            used_ids[alloc["host_id"]] = name
        except (json.JSONDecodeError, KeyError):
            continue

    # Check for conflict
    if candidate_id in used_ids:
        log.error("host_id %d already allocated to '%s' — "
                  "cannot use IP %s as overlay host", candidate_id,
                  used_ids[candidate_id], local_ip)
        log.error("fix: change management IP or manually delete "
                  "/geneve/allocations/%s in etcd", used_ids[candidate_id])
        sys.exit(1)

    # Write allocation
    etcd.put(alloc_key, json.dumps({
        "host_id": candidate_id, "gw_ip": candidate_gw, "mgmt_ip": local_ip,
    }))
    log.info("created allocation: host_id=%d gw_ip=%s", candidate_id, candidate_gw)
    return candidate_id, candidate_gw


# ── Main ────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Pure Linux Geneve overlay agent")
    ap.add_argument("--etcd-host", help="etcd host IP")
    ap.add_argument("--etcd-port", type=int, help="etcd port")
    ap.add_argument("--mgmt-net", help="Management network CIDR")
    ap.add_argument("--bridge", help="Bridge name")
    ap.add_argument("--interval", type=int, help="Lease TTL (seconds)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    c = cfg(args)
    hostname = subprocess.check_output(["hostname", "-s"], text=True).strip()

    # 1. Detect host IP
    local_ip = detect_local_ip(c["MGMT_NET"])
    if not local_ip:
        log.error("no IP on %s", c["MGMT_NET"])
        sys.exit(1)

    # 2. Connect to etcd
    etcd = EtcdClient(c["ETCD_URL"])

    # 3. Check persistent allocation (with conflict detection)
    alloc_key = f"{c['ALLOC_PREFIX']}{hostname}"
    alloc_data = etcd.get(alloc_key)
    if alloc_data:
        try:
            alloc = json.loads(alloc_data)
            host_id = alloc["host_id"]
            gw_ip = alloc["gw_ip"]
            log.info("restored allocation: host_id=%d gw_ip=%s", host_id, gw_ip)
        except (json.JSONDecodeError, KeyError):
            host_id, gw_ip = _allocate_id(etcd, c, local_ip, alloc_key, hostname)
    else:
        host_id, gw_ip = _allocate_id(etcd, c, local_ip, alloc_key, hostname)

    gw_cidr = f"{gw_ip}/{c['PREFIX_LEN']}"
    log.info("host: %s (%s) → gateway: %s", hostname, local_ip, gw_cidr)

    # 4. Create bridge + gateway
    ensure_bridge(c["BRIDGE_NAME"], gw_cidr)

    # 5. Register with lease
    lease_id = etcd.grant_lease(c["LEASE_TTL"])
    etcd_key = f"{c['ETCD_PREFIX']}{hostname}"
    etcd.put(etcd_key, json.dumps({"mgmt_ip": local_ip, "gw_ip": gw_ip}), lease_id=lease_id)
    log.info("registered: %s", etcd_key)

    # 6. Load existing peers
    peers_raw = etcd.get_prefix(c["ETCD_PREFIX"])
    for name, val in peers_raw.items():
        if name == hostname:
            continue
        try:
            info = json.loads(val)
            add_peer(name, info, c)
        except json.JSONDecodeError:
            continue
    log.info("loaded %d peer(s)", len(peers_raw) - 1)

    # 7. Graceful shutdown
    running = True
    def _stop(sig, frame):
        nonlocal running
        log.info("shutting down...")
        running = False
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    # 8. Lease keepalive thread
    def keepalive_loop():
        while running:
            time.sleep(c["LEASE_TTL"] // 2)
            if running:
                etcd.keepalive()
    threading.Thread(target=keepalive_loop, daemon=True).start()

    # 9. Watch for peer changes (auto-reconnect on disconnect)
    log.info("watching etcd %s ...", c["ETCD_PREFIX"])
    while running:
        try:
            for event_type, key, value in etcd.watch_prefix(c["ETCD_PREFIX"]):
                if not running:
                    break
                name = key.replace(c["ETCD_PREFIX"], "")
                if name == hostname:
                    continue
                if event_type == "put":
                    try:
                        info = json.loads(value)
                        log.info("peer joined: %s (%s)", name, info["mgmt_ip"])
                        add_peer(name, info, c)
                    except json.JSONDecodeError:
                        pass
                elif event_type == "delete":
                    log.info("peer left: %s", name)
                    remove_peer(name, c)
        except Exception as e:
            if not running:
                break
            log.warning("watch disconnected: %s — reconnecting in %ds", e, c["CHECK_INTERVAL"])
            time.sleep(c["CHECK_INTERVAL"])
            # Re-register in case lease expired
            try:
                lease_id = etcd.grant_lease(c["LEASE_TTL"])
                etcd.put(etcd_key, json.dumps({"mgmt_ip": local_ip, "gw_ip": gw_ip}), lease_id=lease_id)
                log.info("re-registered: %s", etcd_key)
            except Exception as e2:
                log.error("re-register failed: %s", e2)

    etcd.delete(etcd_key)
    etcd.close()
    log.info("stopped")


if __name__ == "__main__":
    main()
