#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
ovn-node-agent — Auto-discovery LSP daemon (like flanneld).

Watches OVS ports for external_ids:iface-id, auto-creates OVN lsp.
POC scripts only need to create OVS port + set external_ids, agent handles the rest.

Flow:
  1. Ensure overlay logical switch exists
  2. Poll OVS ports with iface-id set
  3. For each: read ovn-ip + ovn-mac from external_ids → lsp-add + lsp-set-addresses
  4. Clean up orphaned lsp (no matching OVS port)

External_ids expected on OVS port:
  iface-id   = lsp name (e.g. "ns-ovn12", "port-ovn12-c1")
  ovn-ip     = IP address (e.g. "172.16.12.100")
  ovn-mac    = MAC address (optional, reads from OVS if absent)

Usage:
    sudo uv run ovn-node-agent.py
    sudo uv run ovn-node-agent.py --central 192.168.200.11
"""

import argparse
import logging
import os
import re
import signal
import subprocess
import sys
import threading
import time

# ── Defaults ────────────────────────────────────────────────

DEFAULTS = {
    "CENTRAL_IP":     "192.168.200.11",
    "LS_NAME":        "overlay",
    "CHECK_INTERVAL": "3",
    "OVERLAY_ROUTE":  "172.16.0.0/16",
}

log = logging.getLogger("ovn-node-agent")

# ── Helpers ─────────────────────────────────────────────────

def run(cmd, check=True):
    log.debug("exec: %s", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        log.warning("cmd failed [%d]: %s  stderr=%s",
                     r.returncode, " ".join(cmd), r.stderr.strip())
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def cfg(args):
    c = dict(DEFAULTS)
    for k in DEFAULTS:
        env = os.environ.get(f"ONA_{k}")
        if env:
            c[k] = env
    if args.central:
        c["CENTRAL_IP"] = args.central
    if args.ls:
        c["LS_NAME"] = args.ls
    if args.interval:
        c["CHECK_INTERVAL"] = str(args.interval)
    c["CHECK_INTERVAL"] = int(c["CHECK_INTERVAL"])
    return c


def nbctl(c, *args):
    return run(["ovn-nbctl", f"--db=tcp:{c['CENTRAL_IP']}:6641"] + list(args), check=False)


# ── OVS port discovery ─────────────────────────────────────

def get_ovs_ports_with_iface_id():
    """Return {iface-id: {mac, ip, ovs_port}} from OVS ports."""
    rc, out, _ = run(["ovs-vsctl", "--format=json", "--columns=name,external_ids",
                       "list", "Interface"], check=False)
    if rc != 0 or not out:
        return {}

    import json
    try:
        rows = json.loads(out).get("data", [])
    except (json.JSONDecodeError, AttributeError):
        return {}

    ports = {}
    for row in rows:
        ovs_name = row[0]
        ext_ids = {}
        # external_ids is [["map", [["key","val"], ...]]]
        if isinstance(row[1], list) and len(row[1]) == 2:
            for pair in row[1][1]:
                ext_ids[pair[0]] = pair[1]

        iface_id = ext_ids.get("iface-id")
        if not iface_id:
            continue

        ports[iface_id] = {
            "ovs_port": ovs_name,
            "ip": ext_ids.get("ovn-ip", ""),
            "mac": ext_ids.get("ovn-mac", ""),
        }

    return ports


def get_ovs_port_mac(ovs_name):
    """Read MAC address of an OVS port from sysfs."""
    rc, out, _ = run(["cat", f"/sys/class/net/{ovs_name}/address"], check=False)
    if rc == 0 and re.match(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$', out):
        return out
    return None




# ── Gateway overlay route ───────────────────────────────────

def ensure_overlay_route(iface_id, overlay_cidr):
    """For gw-* ports: ensure host has overlay route via the host-side veth.
    
    Naming convention:
      iface-id  = gw-ovn12      (lsp name, also the host-side veth name)
      OVS port  = gw-int-ovn12  (br-int side of veth pair)
    The host-side veth device name == iface_id.
    """
    if not iface_id.startswith("gw-"):
        return

    dev = iface_id  # host-side veth name

    # Check if device exists
    rc, _, _ = run(["ip", "link", "show", dev], check=False)
    if rc != 0:
        return

    # Check if route already exists
    rc, out, _ = run(["ip", "route", "show", "dev", dev], check=False)
    if overlay_cidr in out:
        return

    # Add route
    rc, _, err = run(["ip", "route", "add", overlay_cidr, "dev", dev], check=False)
    if rc == 0:
        log.info("added overlay route %s via %s", overlay_cidr, dev)
    else:
        log.debug("route %s via %s: %s", overlay_cidr, dev, err.strip())

# ── OVN lsp management ──────────────────────────────────────

def get_existing_lsp(c):
    """Return set of lsp names in the overlay switch."""
    rc, out, _ = nbctl(c, "lsp-list", c["LS_NAME"])
    if rc != 0 or not out:
        return set()

    names = set()
    for line in out.splitlines():
        # format: <uuid> (<name>)
        m = re.search(r'\(([^)]+)\)', line)
        if m:
            names.add(m.group(1))
    return names


def get_lsp_addresses(c, name):
    """Return addresses string for an lsp, or empty."""
    rc, out, _ = nbctl(c, "lsp-get-addresses", name)
    return out if rc == 0 else ""


def sync_lsp(c, ovs_ports, existing_lsp):
    """Create missing lsp, remove orphaned lsp."""
    db_ok = True

    # ── Create lsp for new OVS ports ──
    for iface_id, info in ovs_ports.items():
        if iface_id in existing_lsp:
            # Already exists — check if addresses match
            current = get_lsp_addresses(c, iface_id)
            mac = info["mac"] or get_ovs_port_mac(info["ovs_port"])
            ip = info["ip"]
            expected = f"{mac} {ip}" if mac and ip else ""
            if expected and expected != current:
                log.info("lsp '%s' address update: %s → %s", iface_id, current, expected)
                nbctl(c, "lsp-set-addresses", iface_id, expected)
            continue

        # New port — create lsp
        mac = info["mac"] or get_ovs_port_mac(info["ovs_port"])
        ip = info["ip"]
        if not mac:
            log.warning("skip lsp '%s': no MAC", iface_id)
            continue
        if not ip:
            log.warning("skip lsp '%s': no ovn-ip in external_ids", iface_id)
            continue

        rc, _, err = nbctl(c, "lsp-add", c["LS_NAME"], iface_id)
        if rc != 0:
            log.warning("lsp-add '%s' failed: %s", iface_id, err)
            db_ok = False
            continue

        nbctl(c, "lsp-set-addresses", iface_id, f"{mac} {ip}")
        nbctl(c, "clear", "Logical_Switch_Port", iface_id, "port_security")
        log.info("created lsp '%s'  MAC=%s IP=%s", iface_id, mac, ip)
        ensure_overlay_route(iface_id, c["OVERLAY_ROUTE"])

    # ── Orphan cleanup skipped (multi-host safe) ──
    # Agent only creates lsp, never deletes.
    # Use POC script 'clean' command to remove lsp when tearing down.

    return db_ok


# ── Main loop ───────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="OVN node agent — auto lsp discovery")
    ap.add_argument("--central", help="Central NB DB IP")
    ap.add_argument("--ls", help="Logical switch name")
    ap.add_argument("--interval", type=int, help="Check interval (seconds)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    c = cfg(args)

    # 1. Ensure logical switch exists
    rc, out, _ = nbctl(c, "ls-list")
    if rc != 0:
        log.error("cannot connect to NB DB at tcp:%s:6641", c["CENTRAL_IP"])
        sys.exit(1)
    if c["LS_NAME"] not in out:
        nbctl(c, "ls-add", c["LS_NAME"])
        log.info("created logical switch '%s'", c["LS_NAME"])
    else:
        log.info("logical switch '%s' exists", c["LS_NAME"])

    # 2. Main loop
    stop_event = threading.Event()
    def _stop(sig, frame):
        log.info("caught signal %s — shutting down", sig)
        stop_event.set()
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    log.info("agent running  (poll every %ds)", c["CHECK_INTERVAL"])
    prev_ports = {}
    while not stop_event.is_set():
        stop_event.wait(c["CHECK_INTERVAL"])
        if stop_event.is_set():
            break

        ovs_ports = get_ovs_ports_with_iface_id()
        existing_lsp = get_existing_lsp(c)

        # Only log when something changes
        if ovs_ports != prev_ports:
            log.info("detected %d OVS port(s) with iface-id: %s",
                     len(ovs_ports), list(ovs_ports.keys()))
            prev_ports = dict(ovs_ports)

        sync_lsp(c, ovs_ports, existing_lsp)

        # Ensure overlay routes for gateway ports
        for iface_id in ovs_ports:
            ensure_overlay_route(iface_id, c["OVERLAY_ROUTE"])

    log.info("stopped")


if __name__ == "__main__":
    main()
