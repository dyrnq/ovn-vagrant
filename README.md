# OVN Vagrant POC

3-node cluster with cross-host Geneve tunnel verification. Three overlay approaches:

1. **Pure Linux kernel** — simplest, just `ip link` + bridge + Geneve (like flannel)
2. **Pure OVS** — OVS standalone + etcd watch + veth
3. **OVN** — full-featured (ACL/DHCP/L3), uses ovn-controller + OpenFlow

## Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│  ovn11 (192.168.200.11) — Central                                 │
│  ┌──────────────────────┐  ┌──────────────────────┐               │
│  │ OVN NB DB (:6641)    │  │ etcd (:2379)         │               │
│  │ OVN SB DB (:6642)    │  │ allocations + peers  │               │
│  │ ovn-northd           │  └──────────────────────┘               │
│  └──────────────────────┘                                         │
│  ovn-controller + ovs-vswitchd                                    │
└─────────────────────┬─────────────────────────────────────────────┘
                      │ Geneve (UDP 6081)
         ┌────────────┼────────────┐
         │            │            │
┌────────┴──────┐  ┌──┴──────────┐ │
│ ovn12 (.12)   │  │ ovn13 (.13) │ │
│ geneve-agent  │  │ geneve-agent│ │
│ ovs-vswitchd  │  │ ovs-vswitchd│ │
│               │  │             │ │
│ gw-ovn12      │  │ gw-ovn13    │ │
│ 172.16.12.1   │  │ 172.16.13.1 │ │
│               │  │             │ │
│ workload      │  │ workload    │ │
│ 172.16.12.x   │  │ 172.16.13.x │ │
└───────────────┘  └─────────────┘ │
```

## Quick Start — Pure OVS (recommended)

```bash
cd /data/work/ovn-vagrant
vagrant up

# 1. Install etcd on central node
vagrant ssh ovn11 -- sudo bash /vagrant/scripts/ovs/geneve-host.sh central

# 2. Install OVS + geneve-agent on each host (auto-starts)
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovs/geneve-host.sh host
vagrant ssh ovn13 -- sudo bash /vagrant/scripts/ovs/geneve-host.sh host

# 3. Verify
vagrant ssh ovn11 -- sudo etcdctl get /geneve/ --prefix
vagrant ssh ovn12 -- sudo journalctl -u geneve-agent -f
```

## Quick Start — Pure Linux Kernel (simplest)

No OVS, no OVN. Just `ip link` + kernel Geneve + Linux bridge.

```bash
cd /data/work/ovn-vagrant
vagrant up

# 1. Central: install etcd
vagrant ssh ovn11 -- sudo bash /vagrant/scripts/kernel/geneve-host.sh central

# 2. Hosts: install agent (auto-creates bridge + Geneve tunnels)
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/kernel/geneve-host.sh host
vagrant ssh ovn13 -- sudo bash /vagrant/scripts/kernel/geneve-host.sh host

# 3. Workloads
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/kernel/poc.sh netns 172.16.12.100/16
vagrant ssh ovn13 -- sudo bash /vagrant/scripts/kernel/poc.sh netns 172.16.13.100/16

# 4. Test
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/kernel/poc.sh verify 172.16.13.100
```

## geneve-agent — Auto-discovery Daemon

Both `ovs/geneve-agent.py` and `kernel/geneve-agent.py` share the same etcd-based
discovery logic. The difference is the forwarding plane:
- **kernel/**: Linux bridge (`br-overlay`) + kernel Geneve devices
- **ovs/**: OVS bridge (`br-int`) + OVS Geneve tunnel ports

Both mirror flanneld: detect host IP → derive subnet → create Geneve tunnel per peer.

```
flanneld                    geneve-agent.py
─────────────               ─────────────────
etcd                        etcd (v3 REST API)
  /coreos.com/network/        /geneve/allocations/ (persistent, no lease)
                              /geneve/peers/ (TTL lease, auto-expire)
cni0 (Linux bridge)         gw-$HOSTNAME (OVS veth, .1 gateway)
flannel.1 (VXLAN)           geneve-$PEER (OVS Geneve tunnel port)
ip route                    ip route (/24 per peer)
watch etcd                  watch etcd (real-time HTTP stream)
```

### Two etcd key spaces

| Key | Lease | Purpose |
|-----|-------|---------|
| `/geneve/allocations/<hostname>` | No | Persistent identity (host_id, gw_ip). Survives reboot. |
| `/geneve/peers/<hostname>` | TTL 30s | Liveness registration (mgmt_ip). Auto-expires on crash. |

### Startup flow

1. Detect host IP → derive overlay subnet (192.168.200.N → 172.16.N.1/24)
2. Connect to etcd
3. Check `/geneve/allocations/<hostname>` → restore or create identity
4. Create gateway veth (`gw-$HOSTNAME`) with unique MAC + overlay route
5. Grant lease + register to `/geneve/peers/<hostname>`
6. Load existing peers → create OVS Geneve tunnel ports + /24 routes
7. Watch `/geneve/peers/` for changes → real-time tunnel/route sync
8. Lease keepalive thread (TTL/2 interval)

### Install + start

```bash
# Central: install etcd
vagrant ssh ovn11 -- sudo bash /vagrant/scripts/ovs/geneve-host.sh central

# Each host: install OVS + geneve-agent (auto-starts)
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovs/geneve-host.sh host
```

Or install agent only (OVS already present):
```bash
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovs/geneve-agent-install.sh
vagrant ssh ovn12 -- sudo systemctl start geneve-agent
```

### Verify

```bash
vagrant ssh ovn12 -- sudo journalctl -u geneve-agent -f
# [geneve-agent] INFO restored allocation: host_id=12 gw_ip=172.16.12.1
# [geneve-agent] INFO gateway gw-ovn12 = 172.16.12.1/24  MAC=52:54:86:92:24:7b
# [geneve-agent] INFO registered: /geneve/peers/ovn12
# [geneve-agent] INFO created OVS tunnel geneve-ovn13 → 192.168.200.13
# [geneve-agent] INFO route 172.16.13.0/24 via gw-ovn12 → geneve-ovn13 (ovn13)
# [geneve-agent] INFO watching etcd /geneve/peers/ ...
```

## Workload Setup

Workloads use /16 addresses (all 172.16.x.x on-link). ARP goes directly through
OVS → Geneve tunnel → remote host. No per-workload route management needed.

### Netns

```bash
# On each host
ip netns add ns-test
ip link add veth-t type veth peer name eth0
ip link set eth0 netns ns-test
MAC=$(openssl rand -hex 6 | sed 's/../&:/g;s/:$//')
ip link set veth-t address "$MAC"
ip link set eth0 address "$MAC"
ovs-vsctl add-port br-int veth-t && ip link set veth-t up
ip netns exec ns-test ip addr add 172.16.12.100/16 dev eth0
ip netns exec ns-test ip link set eth0 up
ip netns exec ns-test ip link set lo up
```

### Docker

```bash
docker run -d --name c1 --network=none alpine:3.21 sleep infinity
PID=$(docker inspect -f '{{.State.Pid}}' c1)
ip link add port-c1 type veth peer name eth0
MAC=$(openssl rand -hex 6 | sed 's/../&:/g;s/:$//')
ip link set port-c1 address "$MAC" && ip link set eth0 address "$MAC"
ip link set eth0 netns $PID
ovs-vsctl add-port br-int port-c1 && ip link set port-c1 up
nsenter -t $PID -n ip addr add 172.16.12.200/16 dev eth0
nsenter -t $PID -n ip link set eth0 up && nsenter -t $PID -n ip link set lo up
```

**Critical**: veth pair must have a unique MAC on each host. OVS FDB collision
(both sides with same MAC) causes silent packet loss.

### Docker POC script

```bash
# After geneve-agent is running on both hosts:
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovs/docker-geneve-poc.sh deploy 172.16.12.200
vagrant ssh ovn13 -- sudo bash /vagrant/scripts/ovs/docker-geneve-poc.sh deploy 172.16.13.200

# Test
vagrant ssh ovn12 -- sudo docker exec geneve-c1 ping -c 3 172.16.13.200

# Clean
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovs/docker-geneve-poc.sh clean
vagrant ssh ovn13 -- sudo bash /vagrant/scripts/ovs/docker-geneve-poc.sh clean
```

## Quick Start — OVN (full-featured)

```bash
# Deploy OVN
vagrant ssh ovn11 -- sudo bash /vagrant/scripts/ovn/ovn-deploy.sh
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovn/ovn-deploy.sh
vagrant ssh ovn13 -- sudo bash /vagrant/scripts/ovn/ovn-deploy.sh

# Verify
vagrant ssh ovn11 -- sudo ovn-sbctl show
```

See `scripts/ovn/ovn-deploy.sh` for OVN Central + Host + REST API deployment.

### OVN POC

```bash
# Netns workload
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovn/ovn-poc.sh host 172.16.12.1/24
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovn/ovn-poc.sh netns 172.16.12.100/16
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovn/ovn-poc.sh verify 172.16.13.100

# Docker workload
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovn/ovn-poc.sh host 172.16.12.1/24
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovn/ovn-poc.sh docker 172.16.12.12/16 ovn12-c1
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovn/ovn-poc.sh verify 172.16.13.13

# Clean
vagrant ssh ovn12 -- sudo bash /vagrant/scripts/ovn/ovn-poc.sh clean
```

## REST API

Runs on ovn11:18081, deployed by `ovn-deploy.sh`. Source: `scripts/ovn/ovn-api.py`.

| Method   | Path                       | Description                        |
| -------- | -------------------------- | ---------------------------------- |
| `POST`   | `/api/bridge/`             | Create logical switch              |
| `DELETE` | `/api/bridge/{name}`       | Delete logical switch              |
| `POST`   | `/api/bridge/port/nic/xml` | Generate libvirt `<interface>` XML |
| `GET`    | `/api/health`              | Health check                       |

## Test Results (pure OVS standalone)

```
Test                               Result
─────────────────────────────────  ────────
netns → local gateway              ✅ 0% loss, ~0.06ms
netns ↔ netns (cross-host)         ✅ 0% loss, ~0.5ms
host → remote gateway              ✅ 0% loss, ~0.5ms
Docker ↔ Docker (cross-host)       ✅ 0% loss, ~0.5ms
Docker → remote gateway            ✅ 0% loss, ~0.6ms
Docker ↔ netns (mixed)              ✅ same OVS L2 domain
etcd watch (real-time discovery)   ✅ working
allocations persistence (reboot)   ✅ working
peers TTL (crash auto-cleanup)     ✅ working
```

## Key Findings — OVS Standalone

- **OVS internal ports** (`type=internal`) cannot receive packets from other
  OVS ports in standalone mode on kernel 6.8. `skb` metadata causes silent drops.
  Neither `ethtool -K` nor `ct()` flow rules fix this.
- **veth pairs** work correctly — `skb_orphan` resets metadata at the veth boundary.
- **veth MAC collision**: if two hosts generate the same random MAC for their
  veth pairs, OVS FDB collides and only one side works.
  Fix: `ip link add veth address 52:54:xx:xx:xx:xx type veth peer name eth0`
  (`geneve-agent.py` does this automatically for the gateway.)
- **ICMP redirect**: gateway veth with `/16` overlay route sends ICMP redirect
  instead of forwarding. Fix: `sysctl send_redirects=0`.

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
│   ├── kernel/                  # Pure Linux kernel approach
│   │   ├── geneve-host.sh       #   Host setup (central/host/clean)
│   │   ├── geneve-agent.py      #   Auto-discovery daemon
│   │   └── poc.sh               #   POC (netns + docker)
│   ├── ovs/                     # Pure OVS approach
│   │   ├── geneve-host.sh       # Host setup (central/host/clean)
│   │   ├── geneve-agent.py      # Auto-discovery daemon (etcd watch)
│   │   ├── geneve-agent-install.sh
│   │   └── docker-geneve-poc.sh # Docker POC
│   └── ovn/                     # OVN approach
│       ├── ovn-deploy.sh        # Central/host/API deploy
│       ├── ovn-api.py           # REST API (FastAPI)
│       ├── ovn-node-agent.py    # Auto-lsp + route daemon
│       ├── ovn-node-agent-install.sh
│       └── ovn-poc.sh           # POC (netns + docker)
└── README.md
```

## vs flannel

|                | flannel              | Pure Kernel           | Pure OVS              | OVN                              |
| -------------- | -------------------- | --------------------- | --------------------- | -------------------------------- |
| Central DB     | etcd                 | etcd                  | etcd                  | ovsdb-server × 2                 |
| Per-host agent | flanneld             | geneve-agent          | geneve-agent          | ovn-node-agent + ovn-controller  |
| Overlay        | VXLAN (UDP 8472)     | Geneve (kernel)       | Geneve (OVS port)     | Geneve (OVN-managed)             |
| Bridge         | cni0                 | br-overlay (Linux)    | gw-$HOSTNAME (OVS)    | gw-$HOSTNAME (veth)              |
| Dependencies   | flannel              | geneve.ko (built-in)  | openvswitch           | ovn-central + ovn-host           |
| Complexity     | Low                  | Lowest                | Low                   | High (OpenFlow 254 tables)       |
| L3/ACL/DHCP    | None                 | None                  | None                  | Built-in                         |
