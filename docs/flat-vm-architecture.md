# hive on flat VMs — architecture

Status: **design / proposal** (not yet implemented). This documents a re-architecture
of hive from nested containers to flat, single-level VMs. The user-facing `hive`
CLI stays identical; only the layer beneath it changes.

## Why

Today a node is a **Kata micro-VM nested inside the Colima VM**:

```
Apple Hypervisor → Colima VM (Linux) → Kata micro-VM per node   ← level 2 = the problem
```

That second, nested level causes nested-virt page-walk thrashing (claude startup 78s),
which we only made tolerable with hugepages (2GB reserved/node, lost on `colima delete`).
Hugepages is a patch on an inherently nested design.

A VM running **directly on Apple's hypervisor** is near-native (it's how Colima/OrbStack
are fast). So we keep VM-grade isolation per node but **stop nesting** — each node is its
own top-level VM, siblings rather than stacked:

```
Apple Hypervisor → node VM 1
                 → node VM 2     ← all level 1, near-native, NO hugepages
                 → gateway VM
```

The hierarchy becomes **logical** (hive tracks which node is whose child) instead of
physical nesting — which is what we want anyway.

## Principle: same CLI, different backend

Every current `hive` verb keeps its meaning and flags. Underneath, Docker primitives are
replaced by VM primitives:

| Docker primitive | VM replacement |
|---|---|
| `docker run` | boot a VM (clone of the golden image) |
| `docker exec` | **SSH** into the running VM (this is the control channel) |
| container labels | hive's own JSON state registry |
| bind mount | **virtiofs** host→guest share |
| internal bridge network | **host-only vmnet** (no NAT) |
| bridge container | **gateway VM** (Squid + dnsmasq + socat) |
| embedded DNS / IPAM | **dnsmasq** on the gateway (DNS + DHCP) |

The single most important replacement: **`docker exec` → SSH**. Every live, no-recreate
toggle (`net`, `github`, `host`) works today by exec'ing into a running container. With a
persistent SSH channel into each running VM, they stay live and no-recreate.

## Topology

```
                         ┌─────────────────────────────────────┐
   host-only vmnet       │  GATEWAY VM   (role of today's       │
   (NO internet route)   │                bridge container)     │
 ┌──────────┐            │  eth0  10.7.0.1  ── node-side       │
 │ node A   │ 10.7.0.10 ─┤    • dnsmasq   DHCP + DNS           │
 │ node B   │ 10.7.0.11 ─┤    • squid     :3128  egress proxy  │
 │ node C   │ 10.7.0.12 ─┤    • socat     :8765 → Mac hostd    │
 └────┬─────┘            │                                     │
      │ SSH              │  eth1  (NAT/shared) ── internet     │ ← only Squid uses this
      │ (control + IDE)  │  nftables: NO L3 forwarding eth0↔eth1│
      ▼                  └─────────────────────────────────────┘
   Mac host
   • hive CLI            • hive-hostd (Mac command channel)
   • Lima / socket_vmnet • VSCode (Remote-SSH UI)
```

The gateway has two interfaces with **no IP forwarding between them**. Nodes sit on a
host-only segment with **no NAT to the internet**; their only path out is Squid at L7.
The internet interface exists solely so Squid can fulfil allowed requests. This is exactly
Docker's "internal network + bridge container" model, rebuilt in VMs — **enforced by
topology, not by config**, so a root user inside a node still has no route to the internet.

## Components

### Host (Mac)
- **`hive` CLI** — same commands; drives Lima + SSH instead of Docker.
- **Lima + socket_vmnet** — VM lifecycle and the host-only network with per-VM MACs.
- **hive-hostd** — unchanged; the opt-in Mac command channel (nodes reach it via the gateway).
- **VSCode** — thin UI; Remote-SSH server runs inside the node VM.
- **State registry** — JSON under `config/` mapping node → {VM id, MAC, IP, parent,
  net/github/host flags}. Replaces docker labels/filters.

### Gateway VM (the "bridge")
A small long-lived VM, started by `hive up`, role-equivalent to today's bridge container:
- **dnsmasq** — DHCP with **per-node MAC reservations** (hive assigns the MAC at create
  time, so it always knows the node's IP) + DNS resolving node names → node IPs
  (node-to-node service discovery) and forwarding external lookups (parity mode).
- **Squid** — `:3128`, the egress chokepoint. Same **open-set by source IP** policy:
  sealed = allowlist only; `net on` = add the node's IP to the open set = full internet.
- **socat** — `:8765 → Mac:8799`, the host-command forward (parity with the bridge).
- **nftables** — default-deny forwarding between node-side and internet-side interfaces.

`net on/off` = SSH into the gateway, edit Squid's open-set, reconfigure — i.e. a direct
port of `bridge_open_set` / `cmd_node_net`, with `docker exec` → SSH.

### Node VM
- Golden-image clone, one NIC on the host-only vmnet.
- IP + DNS + default route from the gateway's dnsmasq (default route → gateway, which drops
  forwarding ⇒ sealed).
- `HTTP(S)_PROXY=http://10.7.0.1:3128`, `NO_PROXY=localhost,…,gateway`; DNS = `10.7.0.1`.
- Runs `sshd` (control channel + IDE) and `claude`.
- Can run Docker **natively** — `dind` stops being a privileged recreate hack.

### Golden node image (prebaked)
Built once, cloned per node. Contains:
- base toolchain + `claude` (today's `hive/node` contents)
- **VSCode Server prebaked** — so a sealed node connects via Remote-SSH instantly, offline
  (no download through the proxy needed)
- `sshd` configured with hive's injected key
- cloud-init/first-boot hook to apply name, proxy env, and DNS

## CLI → VM command mapping

| `hive` command | today | flat-VM implementation | change |
|---|---|---|---|
| `build` | docker build images | build golden image + gateway image (Lima templates) | rework |
| `up` | compose up root+bridge | boot gateway VM (+ optional root node) | rework |
| `down` | stop nodes + compose down | stop node VMs + gateway | rework |
| `status` / `ls` / `tree` | docker ps + labels | read state registry | rework (read-only) |
| `new <name>` | docker run | assign MAC/IP, clone+boot golden VM, register | rework |
| `--parent` | label | registry field | easy |
| `--bind` | bind mount | virtiofs share | easy |
| `--uplink` | extra docker net + ports | node also on a NAT vmnet + host forward | medium |
| `--dind` | `--privileged` + recreate | **native dockerd in the VM, no recreate** | simpler |
| `sh` / `claude` | docker exec | `ssh node -- …` | easy |
| `rm [--purge]` | docker rm + volume rm | destroy VM (+ disk) | easy |
| `join` | docker network connect | attach a VM/host to the host-only net + register | medium |
| `net on/off/status` | squid open-set via exec | squid open-set via **SSH to gateway** | port |
| `github on/off/status` | exec inject token | **SSH** inject token | port |
| `host on/off/status` | exec token + bridge socat | **SSH** token; gateway socat forward | port |
| `dind on/off` | privileged recreate | enable/disable in-VM dockerd (no recreate) | simpler |
| `hostd start/stop/...` | Mac daemon + bridge socat | Mac daemon + **gateway** socat | port |
| `ssh setup` / `ssh` | exec ProxyCommand (no port) | **native Remote-SSH** (real host + sshd) | simpler |
| `github login/--forget` | gh in root via bridge | gh in a node via gateway | port |
| `bridge reload/logs/conf` | manage bridge container | manage **gateway VM** services | port |
| `devcontainer <dir>` | drop .devcontainer | **`hive code <node>`** → `code --remote ssh-remote+hive-<node> /workspace` | replace |
| `doctor` | exec curl isolation tests | same tests over SSH | port |

## What gets better

- **No hugepages, ever** — single-level VMs run near-native.
- **`dind` is native** — a VM just runs Docker; the privileged recreate hack disappears.
- **VSCode is first-class** — each node is a real host; Remote-SSH replaces the exec
  ProxyCommand gymnastics; the VM filesystem shows in the explorer, terminal and all
  tooling run in the VM.
- **True kernel isolation per node** without the nesting tax.

## What is genuinely new work

1. **Lima integration** — golden + gateway VM templates, host-only network via socket_vmnet,
   per-node MAC/IP assignment, clone/boot/destroy lifecycle.
2. **Gateway VM** — dnsmasq (DHCP+DNS) + Squid + socat + nftables, replacing Docker's
   built-in DNS/IPAM/bridge.
3. **State registry** — JSON store replacing docker labels.
4. **SSH control channel** — one mechanism for `net`/`github`/`host`, node-to-node, and IDE.
5. **Spawn speed** — VM boot is seconds vs container ms; mitigate with CoW clones and/or a
   warm pool.

## Open questions / future

- **DNS strictness** — default **parity** (dnsmasq forwards external lookups). Strict mode
  (only Squid resolves, via CONNECT) closes the DNS-tunnel exfil surface; add as a toggle.
- **Tart** — faster CoW clones for many ephemeral nodes; possible future swap for the VM
  backend if spawn latency matters more than Lima's networking ergonomics.
- **Warm pool** — keep N pre-booted nodes to make `hive new` feel instant.
- **Persistence** — gateway/node config lives in images + Lima templates, so it survives
  teardown (unlike today's in-Colima edits lost on `colima delete`).

## Decisions locked

1. Flat VM-per-node, single virtualization level, no hugepages.
2. Identical `hive` CLI; Docker → VM underneath.
3. Gateway VM = the bridge: Squid + dnsmasq (DHCP+DNS) + socat; nodes on host-only vmnet,
   no NAT; enforcement by topology.
4. DNS parity mode by default; strict as a later toggle.
5. Remote-SSH, no devcontainers; `hive code <node>`; VSCode Server prebaked.
6. Lima + socket_vmnet; SSH as the control channel.
