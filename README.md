# OVN Vagrant POC

3-node OVN cluster with cross-host Geneve tunnel verification.

## Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│  ovn11 (192.168.200.11) — Central                                 │
│  ┌──────────────────────┐  ┌──────────────────────┐               │
│  │ OVN NB DB (:6641)    │  │ OVN REST API (:18081)│               │
│  │ OVN SB DB (:6642)    │  │ ovn-api.py (FastAPI)  │               │
│  │ ovn-northd           │  └──────────────────────┘               │
│  └──────────────────────┘                                         │
│  ovn-controller + ovs-vswitchd                                    │
└─────────────────────┬─────────────────────────────────────────────┘
                      │ Geneve (UDP 6081)
         ┌────────────┼────────────┐
         │            │            │
┌────────┴──────┐  ┌──┴──────────┐ │
│ ovn12 (.12)   │  │ ovn13 (.13) │ │
│ ovn-node-agent│  │ ovn-node-agent│
│ ovn-ctrl      │  │ ovn-ctrl    │ │
│ ovs-vswitchd  │  │ ovs-vswitchd│ │
│               │  │             │ │
│ gw-ovn12      │  │ gw-ovn13    │ │
│ 172.16.12.1   │  │ 172.16.13.1 │ │
│ (veth↔gw-int) │  │ (veth↔gw-int)│
│               │  │             │ │
│ ovn12-c1      │  │ ovn13-c1    │ │
│ 172.16.12.12  │  │ 172.16.13.13│ │
└───────────────┘  └─────────────┘ │
```

### How the Geneve tunnel works

1. **ovn-controller** on each host connects to the central **SB DB** (TCP 6642)
2. It discovers peer chassis' **encap IP** (192.168.200.12/13) from the `Encap` table
3. It programs `ovs-vswitchd` to create a **Geneve tunnel port** to each peer
4. When a packet's logical destination MAC resolves to a remote port, `ovn-controller`
   adds an OpenFlow rule in **table 39**: `load:TUNNEL_KEY,output:GENEVE_PORT`
5. The encapsulated Geneve frame travels over the physical network (UDP 6081)
6. On the remote side, table 0 extracts `tunnel_key` → `metadata` → `reg15`,
   and tables 40/64/65 deliver the decapsulated packet to the local port

### Gateway model (like flannel's cni0)

Each host has a **gateway** (veth pair: `gw-$HOSTNAME` ↔ `gw-int-$HOSTNAME`) at `.1` on its /24 subnet.
Workloads connect via veth pair and use `default via .1`. The host also gets a `172.16.0.0/16` overlay route via the gateway (managed by `ovn-node-agent`).

```
flannel:                    OVN:
  etcd          →             ovsdb-server (NB+SB)
  flanneld      →             ovn-node-agent (auto lsp + route daemon)
  cni0 (bridge) →             gw-$HOSTNAME (veth, .1 gateway)
  flannel.1     →             OVN Geneve tunnel (handled by ovn-controller)
```

`ovn-node-agent` watches OVS ports and auto-creates OVN lsp + overlay routes — no manual `lsp-add` or `ip route add`.

## Quick Start

```bash
cd /data/work/ovn-vagrant

# 1. Start VMs (5-10 min first run)
vagrant up

# 2. Deploy OVN on all 3 nodes
vagrant ssh ovn11 -- sudo bash /vagrant/scripts/ovn-deploy.sh
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovn-deploy.sh
vagrant ssh ovn13 -- sudo bash /vagrant/scripts/ovn-deploy.sh

# 3. Verify cluster
vagrant ssh ovn11 -- sudo ovn-sbctl show
# Expected: 3 chassis with Geneve encap IPs

# 4. Start node agents (auto-creates lsp + overlay routes)
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovn-node-agent-install.sh
vagrant ssh ovn13 -- sudo bash /vagrant/scripts/ovn-node-agent-install.sh
vagrant ssh ovn12 -- sudo systemctl start ovn-node-agent
vagrant ssh ovn13 -- sudo systemctl start ovn-node-agent
```

## Docker POC — Cross-Host Geneve Communication

Two Docker containers (`ovn12-c1` on ovn12, `ovn13-c1` on ovn13) communicate
over the OVN Geneve overlay. ovn11 acts as Central only (no containers).

```bash
# Step 1: Setup gateway + container on ovn12 and ovn13
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/docker-ovn-poc.sh deploy
vagrant ssh ovn13 -- sudo bash /vagrant/scripts/docker-ovn-poc.sh deploy

# Step 2: Create switch + ACLs (on ovn11)
vagrant ssh ovn11 -- sudo bash /vagrant/scripts/docker-ovn-poc.sh finish

# Step 3: Verify
vagrant ssh ovn12 -- sudo docker exec ovn12-c1 ping -c 3 172.16.13.13
vagrant ssh ovn13 -- sudo docker exec ovn13-c1 ping -c 3 172.16.12.12

# Step 4: Clean up
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/docker-ovn-poc.sh clean
vagrant ssh ovn13 -- sudo bash /vagrant/scripts/docker-ovn-poc.sh clean
```

### Expected output

```bash
# deploy on ovn12:
# [ovn12] Setting up gateway gw-ovn12 (172.16.12.1/24)
# [ovn12]   Gateway 172.16.12.1 ready (veth: gw-ovn12 ↔ gw-int-ovn12)
# [ovn12] Setting up ovn12-c1 (172.16.12.12/16 via gw 172.16.12.1)
# [ovn12]   MAC: d2:c2:98:ac:73:e2 — ovn-node-agent will auto-create lsp

# ping from ovn12:
# 64 bytes from 172.16.13.13: seq=0 ttl=64 time=1.856 ms
# 3 packets transmitted, 3 packets received, 0% packet loss
```

## Netns POC — Lightweight Overlay Test

Same gateway model, no Docker required. Uses bare network namespaces.

```bash
# Central
vagrant ssh ovn11 -- sudo bash /vagrant/scripts/netns-ovn-poc.sh central

# Host — create gateway
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/netns-ovn-poc.sh host 172.16.12.1/24
vagrant ssh ovn13 -- sudo bash /vagrant/scripts/netns-ovn-poc.sh host 172.16.13.1/24

# Add test workloads
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/netns-ovn-poc.sh test 172.16.12.100/16
vagrant ssh ovn13 -- sudo bash /vagrant/scripts/netns-ovn-poc.sh test 172.16.13.100/16

# Verify
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/netns-ovn-poc.sh verify 172.16.13.100
```

## Inspecting the Geneve Tunnel

```bash
# View all Geneve tunnel ports
vagrant ssh ovn12 -- sudo ovs-vsctl show | grep -A3 geneve

# Track traffic through tunnels (tx/rx counters)
vagrant ssh ovn12 -- sudo ovs-ofctl dump-ports br-int

# Trace a packet through the logical pipeline
vagrant ssh ovn11 -- sudo ovn-trace overlay \
    'inport=="port-ovn12-c1" && eth.dst==72:e4:c0:0a:46:ab && ip4.dst==172.16.13.13'

# View SB DB port bindings (shows chassis + tunnel_key)
vagrant ssh ovn11 -- sudo ovn-sbctl list Port_Binding | grep -E 'logical_port|chassis|tunnel_key'
```

## REST API

Runs on ovn11:18081, deployed by `ovn-deploy.sh`. Source: `scripts/ovn-api.py`.

| Method   | Path                       | Description                        |
| -------- | -------------------------- | ---------------------------------- |
| `POST`   | `/api/bridge/`             | Create logical switch              |
| `DELETE` | `/api/bridge/{name}`       | Delete logical switch              |
| `POST`   | `/api/bridge/port/nic/xml` | Generate libvirt `<interface>` XML |
| `GET`    | `/api/health`              | Health check                       |

## Container-to-OVN Data Path

```
Docker container (netns)
    │  veth pair: eth0 ↔ port-ovn12-c1
    ▼
OVS port (port-ovn12-c1, veth host-side)
    │  external_ids:iface-id=port-ovn12-c1  ← agent creates OVN lsp
    ▼
OVS bridge (br-int) — OpenFlow pipeline
    │  Table 0:   local ingress → reg14, metadata
    │  Table 8:   ACL evaluation (ip4 → allow)
    │  Table 27:  L2 lookup → outport=port-ovn13-c1
    │  Table 35:  reg15=tunnel_key
    │  Table 39:  Geneve encap → output to tunnel port
    ▼
Geneve tunnel (UDP 6081 → 192.168.200.13)
    ▼
Remote br-int → decap → local delivery → port-ovn13-c1 → veth → container
```

## ovn-node-agent — Auto-discovery Daemon

Watches OVS ports for `external_ids:iface-id`, auto-creates OVN lsp.
For gateway ports (`gw-*`), also manages the `172.16.0.0/16` overlay host route.

```
POC script creates OVS port (iface-id + ovn-ip)
    → agent detects new port
    → agent calls ovn-nbctl lsp-add + lsp-set-addresses
    → for gw-* ports: agent adds ip route 172.16.0.0/16 via gw-$HOSTNAME
    → ovn-controller binds lsp to OVS port
    → Geneve tunnel ready
```

### Install + start

```bash
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovn-node-agent-install.sh
vagrant ssh ovn12 -- sudo systemctl start ovn-node-agent
```

### Verify

```bash
vagrant ssh ovn12 -- sudo journalctl -u ovn-node-agent -f
# ovn-node-agent: detected 3 OVS port(s) with iface-id: ['gw-ovn12', 'ns-ovn12', 'port-ovn12-c1']
# ovn-node-agent: created lsp 'gw-ovn12'  MAC=82:c5:61:cb:11:5e IP=172.16.12.1
# ovn-node-agent: added overlay route 172.16.0.0/16 via gw-ovn12
# ovn-node-agent: agent running  (poll every 3s)
```

### How it works

OVS port `external_ids` expected:
- `iface-id` = lsp name (e.g. `gw-ovn12`, `ns-ovn12`, `port-ovn12-c1`)
- `ovn-ip` = IP address for the lsp

Agent polls every 3s:
- Creates missing lsp for any port with `iface-id` + `ovn-ip`
- For `gw-*` ports: also ensures `172.16.0.0/16` host route via the veth
- Never deletes lsp (use POC `clean` command)

## Vagrant Commands

```bash
vagrant status          # List VMs
vagrant ssh ovn11       # SSH into a VM
vagrant suspend         # Pause all VMs
vagrant resume          # Resume all VMs
vagrant destroy -f      # Destroy all VMs
```

## Files

```
/data/work/ovn-vagrant/
├── Vagrantfile                  # 3 nodes, 192.168.200.0/24, 2 CPU / 2G RAM each
├── insecure_private_key         # Vagrant default SSH key
├── scripts/
│   ├── provision.sh             # System init (mirrors, sysctl, base tools)
│   ├── ovn-deploy.sh            # OVN one-shot deploy (auto-detects Central vs Host)
│   ├── ovn-node-agent.py        # Auto-discovery daemon (lsp + overlay route)
│   ├── ovn-node-agent-install.sh
│   ├── netns-ovn-poc.sh         # Netns overlay with bridge gateway model
│   ├── docker-ovn-poc.sh        # Docker overlay with bridge gateway model
│   └── ovn-api.py               # REST API (FastAPI + uvicorn)
└── README.md
```

## Key Points

- **uv** manages Python dependencies via PEP 723 inline metadata — no `pip install` needed
- **OVN 24.03** from Ubuntu 24.04 apt (`ovn-central` + `ovn-host` packages)
- **Geneve** encapsulation (UDP 6081) with `key=flow` — tunnel key is set per-packet
  by OpenFlow, so a single tunnel port handles all logical switches
- **Gateway**: each host has a veth pair (`gw-$HOSTNAME` ↔ `gw-int-$HOSTNAME`) at `.1` on its /24.
  `ovn-node-agent` auto-creates OVN lsp and manages `172.16.0.0/16` overlay route
- **Workload MAC**: veth pair MACs must match on both ends — scripts sync MAC from host-side to
  netns/container-side before moving the peer
- **ovn-node-agent**: polls OVS ports every 3s, creates lsp from `external_ids:iface-id` + `ovn-ip`,
  manages overlay routes for `gw-*` ports
- **Central DB access**: `ovn-nbctl` runs on each host but connects to the central
  NB DB via `--db=tcp:$CENTRAL_IP:6641`

## Known Limitations

- **L3 routing (separate subnets)** via OVN Logical Router requires the LRP port
  to be bound to a gateway chassis. POC uses L2 flat overlay only.
  Production KVM/libvirt environments can use distributed logical routing.

## vs flannel

|                | flannel              | OVN                                        |
| -------------- | -------------------- | ------------------------------------------ |
| Central DB     | etcd (1 process)     | ovsdb-server × 2                           |
| Per-host agent | flanneld             | ovn-node-agent (auto-lsp + route) + ovn-controller |
| Overlay        | VXLAN (UDP 8472)     | Geneve (UDP 6081)                          |
| Bridge         | cni0                 | gw-$HOSTNAME (veth pair, .1 gateway)       |
| Tunnel key     | Static VNI           | Per-packet flow (key=flow)                 |
| Port register  | CNI plugin           | ovn-node-agent auto-lsp                    |
| Route mgmt     | flanneld subnet lease| ovn-node-agent overlay route               |
| Isolation      | None                 | L2/L3/ACL/DHCP                             |
