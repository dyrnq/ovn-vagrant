#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["httpx"]
# ///
"""
geneve-agent — Pure OVS Geneve overlay daemon with etcd v3 watch (like flanneld).

Uses etcd v3 REST API (gRPC-gateway) — no protobuf/gRPC dependency.

Architecture (mirrors flannel exactly):
  etcd           →  etcd (same, stores host→subnet mapping)
  flanneld       →  geneve-agent.py (this)
  cni0           →  gw-$HOSTNAME (veth, .1 gateway)
  flannel.1      →  geneve-$PEER (Linux Geneve device, one per peer)

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
    if args.prefix:
        c["ETCD_PREFIX"] = args.prefix
    if args.mgmt_net:
        c["MGMT_NET"] = args.mgmt_net
    if args.interval:
        c["LEASE_TTL"] = args.interval
    c["ETCD_PORT"] = int(c["ETCD_PORT"])
    c["LEASE_TTL"] = int(c["LEASE_TTL"])
    c["PREFIX_LEN"] = int(c["OVERLAY_MASK"])
    c["ETCD_URL"] = f"http://{c['ETCD_HOST']}:{c['ETCD_PORT']}"
    return c


# ── etcd v3 REST API ────────────────────────────────────────

class EtcdClient:
    """etcd v3 REST API client (gRPC-gateway)."""

    def __init__(self, url):
        self.url = url
        self.client = httpx.Client(base_url=url, timeout=10)
        self.lease_id = None

    def grant_lease(self, ttl):
        """Create a lease with TTL seconds."""
        r = self.client.post("/v3/lease/grant", json={"TTL": ttl})
        r.raise_for_status()
        self.lease_id = r.json()["ID"]
        log.debug("lease granted: id=%s ttl=%d", self.lease_id, ttl)
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
        """Put a key-value pair."""
        payload = {"key": b64e(key), "value": b64e(value)}
        if lease_id:
            payload["lease"] = str(lease_id)
        r = self.client.post("/v3/kv/put", json=payload)
        r.raise_for_status()

    def get(self, key):
        """Get a single key. Returns value or None if not found."""
        r = self.client.post("/v3/kv/range", json={"key": b64e(key)})
        r.raise_for_status()
        kvs = r.json().get("kvs", [])
        if kvs:
            return b64d(kvs[0]["value"])
        return None

    def get_prefix(self, prefix):
        """Get all keys with prefix. Returns {key: value} dict."""
        payload = {
            "key": b64e(prefix),
            "range_end": b64e(prefix + "\xff"),
        }
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
        """Delete a key."""
        self.client.post("/v3/kv/deleterange",
                         json={"key": b64e(key)})

    def watch_prefix(self, prefix, start_revision=None):
        """Watch for changes on a prefix. Yields (event_type, key, value).
        
        Uses HTTP streaming — blocks and yields events.
        """
        payload = {
            "create_request": {
                "key": b64e(prefix),
                "range_end": b64e(prefix + "\xff"),
            }
        }
        if start_revision:
            payload["create_request"]["start_revision"] = start_revision

        with self.client.stream("POST", "/v3/watch",
                                json=payload) as r:
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


# ── Geneve tunnel management (OVS tunnel port) ──────────────

def geneve_port_name(peer_name):
    """OVS Geneve tunnel port name for a peer."""
    return f"geneve-{peer_name}"


def ensure_geneve_tunnel(port_name, remote_ip):
    """Create an OVS Geneve tunnel port to remote_ip.
    
    OVS handles L2 MAC learning across the tunnel automatically.
    No OpenFlow rules needed — standard L2 forwarding works.
    """
    # Check if port already exists on br-int
    rc, out, _ = run(["ovs-vsctl", "list-ifaces", "br-int"], check=False)
    if rc == 0 and port_name in out:
        return True

    rc, _, err = run([
        "ovs-vsctl", "add-port", "br-int", port_name,
        "--", "set", "interface", port_name,
        "type=geneve",
        f"options:remote_ip={remote_ip}",
        "options:key=1",
    ])  # critical
    if rc != 0:
        log.warning("create OVS geneve %s → %s failed: %s", port_name, remote_ip, err)
        return False

    log.info("created OVS tunnel %s → %s", port_name, remote_ip)
    return True


def remove_geneve_tunnel(port_name):
    """Remove an OVS Geneve tunnel port."""
    rc, _, _ = run(["ovs-vsctl", "--if-exists", "del-port", "br-int", port_name], check=False)
    if rc == 0:
        log.info("removed OVS tunnel %s", port_name)


def add_peer(name, info, c, hostname):
    """Create OVS Geneve tunnel + /24 route for a peer."""
    port_name = geneve_port_name(name)
    if ensure_geneve_tunnel(port_name, info["mgmt_ip"]):
        # Route: peer's /24 subnet via our gateway veth
        # Packet goes: host → gw veth → br-int → OVS L2 → Geneve → peer
        peer_id = info["gw_ip"].rsplit(".", 1)[0].split(".")[-1]
        subnet = f"{c['OVERLAY_PREFIX']}.{peer_id}.0/{c['PREFIX_LEN']}"
        gw_dev = f"gw-{hostname}"
        run(["ip", "route", "replace", subnet, "dev", gw_dev], check=False)
        log.info("route %s via %s → %s (%s)", subnet, gw_dev, port_name, name)


def remove_peer(name, c):
    """Remove OVS tunnel + host route for a peer."""
    port_name = geneve_port_name(name)
    remove_geneve_tunnel(port_name)
    m = re.search(r'(\d+)$', name)
    if m:
        subnet = f"{c['OVERLAY_PREFIX']}.{m.group(1)}.0/{c['PREFIX_LEN']}"
        run(["ip", "route", "del", subnet], check=False)


# ── Gateway ─────────────────────────────────────────────────

def gen_mac():
    """Generate a random locally-administered unicast MAC."""
    import random
    b = [0x52, 0x54, random.randint(0, 255), random.randint(0, 255),
         random.randint(0, 255), random.randint(0, 255)]
    return ":".join(f"{x:02x}" for x in b)


def ensure_gateway(c, hostname, gw_ip):
    gw_dev = f"gw-{hostname}"
    gw_int = f"gw-int-{hostname}"
    gw_cidr = f"{gw_ip}/{c['PREFIX_LEN']}"

    rc, _, _ = run(["ip", "link", "show", gw_dev], check=False)
    if rc == 0:
        rc2, out, _ = run(["ip", "-4", "-o", "addr", "show", "dev", gw_dev], check=False)
        if rc2 == 0 and gw_ip in out:
            return True

    run(["ip", "link", "del", gw_dev], check=False)  # cleanup, ok to fail

    # Generate unique MAC before creating veth (avoids FDB collision)
    mac = gen_mac()
    run(["ip", "link", "add", gw_dev, "address", mac,
         "type", "veth", "peer", "name", gw_int])

    # Attach OVS side to br-int
    run(["ovs-vsctl", "--if-exists", "del-port", "br-int", gw_int], check=False)  # cleanup
    run(["ovs-vsctl", "add-port", "br-int", gw_int])
    run(["ip", "link", "set", gw_int, "up"])

    # Assign gateway IP
    run(["ip", "addr", "flush", "dev", gw_dev], check=False)  # cleanup
    run(["ip", "addr", "add", gw_cidr, "dev", gw_dev])
    run(["ip", "link", "set", gw_dev, "up"])

    # Disable ICMP redirect (gateway must forward, not redirect)
    run(["sysctl", "-w", f"net.ipv4.conf.{gw_dev}.send_redirects=0"], check=False)
    run(["sysctl", "-w", "net.ipv4.conf.all.send_redirects=0"], check=False)

    # Overlay route for host → remote workloads/gateways
    overlay_route = f"{c['OVERLAY_PREFIX']}.0.0/{c['PREFIX_LEN']}"
    run(["ip", "route", "replace", overlay_route, "dev", gw_dev], check=False)

    log.info("gateway %s = %s  MAC=%s", gw_dev, gw_cidr, mac)
    return True



# ── Allocation with conflict detection ──────────────────────

def _allocate_id(etcd, c, local_ip, alloc_key, hostname):
    """Allocate host_id with conflict detection."""
    candidate_id = int(local_ip.rsplit(".", 1)[1])
    candidate_gw = f"{c['OVERLAY_PREFIX']}.{candidate_id}.1"

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

    if candidate_id in used_ids:
        log.error("host_id %d already allocated to '%s' — "
                  "cannot use IP %s as overlay host", candidate_id,
                  used_ids[candidate_id], local_ip)
        log.error("fix: change management IP or manually delete "
                  "/geneve/allocations/%s in etcd", used_ids[candidate_id])
        sys.exit(1)

    etcd.put(alloc_key, json.dumps({
        "host_id": candidate_id, "gw_ip": candidate_gw, "mgmt_ip": local_ip,
    }))
    log.info("created allocation: host_id=%d gw_ip=%s", candidate_id, candidate_gw)
    return candidate_id, candidate_gw


# ── Main ────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Pure OVS Geneve agent (etcd watch)")
    ap.add_argument("--etcd-host", help="etcd host IP")
    ap.add_argument("--etcd-port", type=int, help="etcd port")
    ap.add_argument("--prefix", help="etcd key prefix")
    ap.add_argument("--mgmt-net", help="Management network CIDR")
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

    log.info("host: %s (%s) → gateway: %s/%s",
             hostname, local_ip, gw_ip, c["PREFIX_LEN"])

    # 4. Ensure gateway
    ensure_gateway(c, hostname, gw_ip)

    # 5. Register with lease (auto-expire on crash)
    lease_id = etcd.grant_lease(c["LEASE_TTL"])
    etcd_key = f"{c['ETCD_PREFIX']}{hostname}"
    etcd_value = json.dumps({"mgmt_ip": local_ip, "gw_ip": gw_ip})
    etcd.put(etcd_key, etcd_value, lease_id=lease_id)
    log.info("registered: %s", etcd_key)

    # 6. Load existing peers + create tunnels
    peers_raw = etcd.get_prefix(c["ETCD_PREFIX"])
    for name, val in peers_raw.items():
        if name == hostname:
            continue
        try:
            info = json.loads(val)
            add_peer(name, info, c, hostname)
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
    t = threading.Thread(target=keepalive_loop, daemon=True)
    t.start()

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
                        add_peer(name, info, c, hostname)
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
