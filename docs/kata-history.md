# Kata containers in hive — what we tried, why it worked, why we backed out

Status: **abandoned / historical record.** Nodes run on **runc** (the engine
default). This file exists so the Kata experiment isn't lost; nothing here is
wired in. See also `docs/flat-vm-architecture.md` for the successor idea that
was explored and also shelved.

## What we were solving

A hive node is a Docker container. runc shares the host kernel, so a node is
isolated by namespaces/cgroups, not by a kernel boundary. We wanted **true
kernel isolation per node** — a compromised node should not be one kernel bug
away from the other nodes or the host.

## What we did

Made the node OCI runtime **pluggable** (commit `cd58acb`) and ran nodes under
**Kata Containers 3.31.0**, which gives each container its own lightweight VM
and kernel.

- `config/runtime` (untracked file) held `kata`; `bin/hive` reads it into
  `NODE_RUNTIME` (bin/hive:37-42) and passes `docker run --runtime "$NODE_RUNTIME"`
  (~bin/hive:221). Empty file / no file = runc.
- Runtime registered in the engine as `io.containerd.kata.v2`.
- A **shim wrapper** stripped the `time` namespace from the OCI spec, which the
  kata-agent rejected.
- Removed `pmu=off` from the kata kernel params (it broke boot on this setup).

It worked — nodes booted as micro-VMs.

## Why it was slow, and the hugepages "fix"

The kata micro-VM runs **nested inside the Colima VM**:

```
Apple Hypervisor → Colima VM (Linux) → Kata micro-VM per node   ← nested = the problem
```

Nested virtualization makes guest page-table walks brutally expensive (the
hardware has to walk two levels of page tables). `claude` startup measured
**~78s**. The link: a small TLB can't cover a large process, so every TLB miss
triggers a full nested page walk.

**Hugepages fixed it:** reserving **1280 × 2MB hugepages** let one TLB entry
cover a large span, so misses (and their nested walks) nearly vanished —
startup dropped **78s → ~2.2s**.

## Why we backed out

- Hugepages cost **~2GB reserved per node** and are **lost on `colima delete`**
  (they live in the Colima VM, not in any image or template) — a fragile patch
  on an inherently nested design.
- The slowness was *purely* the second, nested virtualization level. A VM
  running **directly** on Apple's hypervisor is near-native, so the cleaner
  answer is to **stop nesting** (flat VM-per-node) rather than to keep tuning a
  nested one. That successor design is in `docs/flat-vm-architecture.md` (also
  not implemented).
- For now the pragmatic choice was to **revert to runc**: identical CLI, no
  hugepages, no nesting tax. We trade kernel-grade isolation back for namespace
  isolation until/unless the flat-VM work is picked up.

## How to re-enable Kata (if ever wanted)

The machinery is inert, not deleted:

1. Re-register the Kata runtime in the Colima/engine (`io.containerd.kata.v2`),
   re-apply the shim wrapper (strip `time` ns) and the kernel-param tweak.
2. Reserve hugepages in the Colima VM (1280 × 2MB) — required for usable speed.
3. Create `hive/config/runtime` containing `kata` (or export `HIVE_RUNTIME=kata`).
4. `hive new <node>` — new nodes pick up the runtime. Existing runc nodes must
   be recreated to switch.
