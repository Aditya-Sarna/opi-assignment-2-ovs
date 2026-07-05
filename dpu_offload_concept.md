# From Software OVS to Hardware Offload on NVIDIA BlueField-3

This document explains how the datapath implemented in this submission — KubeVirt CirrOS
VMs bridged into a kernel Open vSwitch `br1` through Multus and ovs-cni — transforms when
the same logical topology is deployed on an NVIDIA BlueField-3 DPU with vDPA, switchdev
mode, and OVS-DOCA. The guiding principle: **the Kubernetes control plane and the tenant
intent stay identical; only where packets are processed changes.**

## 1. What the implemented software datapath does, and what it costs

### 1.1 Packet walk (as built in this submission)

When `vm-a` pings `ovs-ping-pod` across `br1`:

```
CirrOS guest (eth1, virtio-net driver)
  └─ virtqueue → QEMU / vhost-net (host kernel)          [copy + context switch]
      └─ tap device in virt-launcher pod netns
          └─ KubeVirt in-pod bridge → pod interface net1  [kernel bridging]
              └─ veth pair (Multus/ovs-cni created)
                  └─ OVS port on br1                      [flow lookup]
                      └─ ovs kernel datapath: match megaflow cache,
                         miss → upcall to ovs-vswitchd (slow path),
                         install flow, forward              [host CPU cycles]
                          └─ peer veth → destination netns
```

Every hop above runs on the **host CPU**. The measurable evidence in
`verification_flows.json` shows exactly this:

- The OpenFlow table contains the standalone `priority=0 actions=NORMAL` rule — OVS acting
  as a learning L2 switch, with `n_packets`/`n_bytes` incremented by the ping traffic.
- The **datapath flow cache** entries (`recirc_id(0),in_port(3),eth(src=02:a0:...)...`)
  are the megaflows `ovs-vswitchd` installed after the first-packet upcall. On a DPU these
  same entries are what get programmed into hardware instead.
- The **FDB** shows each endpoint's MAC learned on its bridge port.

### 1.2 The cost model

| Cost | Where it is paid in software |
|---|---|
| virtio backend processing | vhost-net kernel thread per queue (host CPU) |
| First packet of each flow | upcall to `ovs-vswitchd` in userspace (slow path) |
| Every subsequent packet | kernel datapath lookup + forwarding (host CPU) |
| Encap/decap (the VXLAN mesh between nodes) | host kernel |
| Memory copies | guest ↔ host buffer copies per packet |

At lab scale this is invisible. At 100/200/400G with thousands of flows, the "datapath
tax" consumes CPU cores that should be running tenant VMs — which is precisely the problem
DPUs exist to solve.

## 2. BlueField-3 building blocks

The BlueField-3 combines a ConnectX-7 NIC, 16 Arm Cortex-A78 cores running Linux, and a
programmable **eSwitch** (embedded switch ASIC). Four technologies map the software lab
onto that hardware:

### 2.1 SR-IOV and switchdev mode

The physical function (PF) is switched from "legacy" to **switchdev** mode:

```bash
devlink dev eswitch set pci/0000:03:00.0 mode switchdev
echo 8 > /sys/class/net/p0/device/sriov_numvfs
```

This does two things:

1. Creates **Virtual Functions (VFs)** — hardware NIC slices assignable to workloads.
2. Creates a **representor** netdevice (`pf0vf0`, `pf0vf1`, ...) for each VF. A representor
   is the eSwitch-side twin of a VF: packets a VF sends appear on its representor, and
   whatever is transmitted on the representor reaches the VF.

**The representor replaces the veth host-leg from this lab.** Where ovs-cni today plugs a
veth into `br1`, on BlueField-3 it plugs in the VF representor — same `ovs-vsctl add-port`,
same OpenFlow semantics:

```bash
ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
ovs-vsctl add-br br1
ovs-vsctl add-port br1 p0        # uplink to the fabric
ovs-vsctl add-port br1 pf0vf0    # vm-a's VF representor
ovs-vsctl add-port br1 pf0vf1    # vm-b's VF representor
```

### 2.2 Hardware flow offload (the eSwitch)

With `hw-offload=true`, the first packet of a flow still goes through OVS's slow path —
but the resulting flow entry is programmed **into the eSwitch's hardware flow tables**
(via TC flower / DOCA) instead of only the kernel cache. From the second packet on, frames
travel **VF → eSwitch match → destination VF/uplink** entirely in silicon. The host (or
even the DPU Arm cores) never see them.

Verification changes accordingly — the same commands used in this assignment gain one
decisive marker:

```
# ovs-appctl dpctl/dump-flows type=offloaded
recirc_id(0),in_port(pf0vf0),eth(src=02:a0:00:00:00:0a,...),eth_type(0x0800),ipv4(frag=no),
  packets:98421, bytes:9645258, used:0.180s, offloaded:yes, dp:tc, actions:pf0vf1
```

`offloaded:yes` is the difference between this lab and production: the flow entry is
identical in meaning, but its `packets:` counter is now maintained by hardware.

### 2.3 vDPA — virtio Data Path Acceleration

SR-IOV alone would force vendor-specific drivers into the guest and break live migration.
**vDPA** fixes that split:

- **Control plane:** the guest keeps the standard `virtio-net` driver — the exact same
  driver CirrOS used in this lab. Nothing inside the VM changes.
- **Data plane:** the virtio ring layout is implemented by the ConnectX-7 hardware. The
  guest's TX/RX descriptors are consumed by the NIC via DMA, not by a vhost-net kernel
  thread.

The host runs the `vhost-vdpa` bus driver; QEMU attaches the VM's NIC to a
`/dev/vhost-vdpa-N` device instead of a tap. The KubeVirt packet walk collapses from seven
software hops to:

```
CirrOS guest (virtio-net, unchanged)
  └─ virtqueue ── DMA ──> ConnectX-7 / eSwitch flow match ──> destination
```

### 2.4 OVS-DOCA on the DPU Arm cores

In the full BlueField deployment model, `ovs-vswitchd` itself moves off the host onto the
DPU's Arm cores, as **OVS-DOCA** — NVIDIA's OVS distribution whose datapath provider uses
the DOCA Flow SDK to program the eSwitch pipeline directly (successor to OVS-DPDK's rte_flow
offload, with larger hardware flow scale and pipeline features).

Operationally it is still OVS: `ovs-vsctl`, `ovs-ofctl dump-flows`, OpenFlow controllers,
and the NORMAL action all work as in this lab. The host becomes a pure tenant machine:
even the infrastructure control plane is isolated on the DPU — the basis of the zero-trust
model, and of the OPI (Open Programmable Infrastructure) project's goal of a vendor-neutral
provisioning/management API for exactly this class of device.

## 3. Side-by-side: what changes, what does not

| Layer | This submission (software) | BlueField-3 (offloaded) |
|---|---|---|
| Kubernetes / KubeVirt / Multus | unchanged | unchanged |
| `NetworkAttachmentDefinition` | `type: ovs, bridge: br1` | same, plus `k8s.v1.cni.cncf.io/resourceName` pointing at a VF/vDPA device pool |
| VM interface binding | `bridge: {}` on tap | `sriov: {}` / vDPA binding (VF passed to QEMU via vfio or vhost-vdpa) |
| Guest driver | virtio-net | virtio-net (**unchanged** — the point of vDPA) |
| Bridge port for the VM | veth host-leg | VF **representor** (switchdev) |
| OVS process location | host kernel + userspace | DPU Arm cores (OVS-DOCA) |
| Flow execution | kernel megaflow cache, host CPU | eSwitch ASIC, `offloaded:yes` |
| Node-to-node overlay | VXLAN in host kernel (this lab's mesh) | VXLAN encap/decap in eSwitch hardware |
| Extra K8s components | none | SR-IOV device plugin (+ network resources injector) to schedule VFs |
| Host CPU per packet | O(packet rate) | ~zero after first packet of each flow |

## 4. The same assignment, replayed on a BlueField-3

Conceptually, re-running this submission's verification on a DPU host:

1. `cluster_setup.sh` equivalent: provision switchdev mode + VFs (or consume them via the
   SR-IOV device plugin), start OVS-DOCA on the DPU, `ovs-vsctl add-br br1` **on the DPU**.
2. `manifests.yaml`: the NAD gains a `resourceName` for the VF pool; the VMs swap
   `bridge: {}` for the SR-IOV/vDPA binding. Static IPs, MACs, and topology are untouched.
3. `ping_results.txt`: identical test, identical tooling — the pings now cross the eSwitch.
4. `verification_flows.json`: same dump commands; the datapath flows now carry
   `offloaded:yes, dp:tc` and hardware-maintained counters, and per-VF representor
   statistics become visible via `devlink port` / `ethtool -S pf0vf0`.

That symmetry is the entire argument for building the software lab first: every operational
concept — bridge, port, flow, FDB, NORMAL switching, flow-cache verification — carries over
one-to-one; the hardware merely changes *where* the datapath executes.

## 5. References

- ovs-cni hardware offload guide: https://github.com/k8snetworkplumbingwg/ovs-cni/blob/main/docs/ovs-offload.md
- KubeVirt interfaces and networks (bridge / SR-IOV bindings): https://kubevirt.io/user-guide/network/interfaces_and_networks/
- NVIDIA OVS-DOCA documentation: https://docs.nvidia.com/doca/sdk/openvswitch+offload/index.html
- NVIDIA BlueField-3 networking platform: https://www.nvidia.com/en-us/networking/products/data-processing-unit/
- vDPA kernel framework: https://docs.kernel.org/networking/vdpa.html
- Open vSwitch hardware offload (switchdev/TC): https://docs.openvswitch.org/en/latest/howto/tc-offload/
- OPI project: https://opiproject.org/
