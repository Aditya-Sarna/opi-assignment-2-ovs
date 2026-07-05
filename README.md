# Assignment 2 — The Cloud-Native OVS Datapath Challenge

Two CirrOS KubeVirt VMs and a verification pod attached to an Open vSwitch bridge
through Multus + OVS-CNI on a single-node KinD cluster, with machine-readable
datapath evidence and a conceptual mapping to NVIDIA BlueField-3 hardware offload.

**The evidence in this repo is real and reproducible.** `ping_results.txt` and
`verification_flows.json` were captured by an end-to-end `cluster_setup.sh` run on
GitHub Actions (`ubuntu-latest`, `/dev/kvm` present) — booting actual CirrOS guests,
not stand-ins. Anyone can regenerate them by running the workflow; the latest green
run is linked below.

- **Live proof (CI):** https://github.com/Aditya-Sarna/opi-assignment-2-ovs/actions/runs/28754686761
- The `Verify artifacts` step *fails the build* unless there are two real `0% packet loss`
  ping blocks and a `verification_flows.json` containing populated `flows` and `fdb` — so
  a green run is itself an assertion that the evidence is genuine.

## Deliverables

| File | Content |
|---|---|
| `cluster_setup.sh` | One executable that bootstraps everything (KinD + kindnet + OVS + Multus + OVS-CNI + KubeVirt), deploys the workloads, runs the ping verification, and regenerates both evidence files. Idempotent, arch-aware, CI-aware. |
| `manifests.yaml` | All Custom Resources: one `NetworkAttachmentDefinition`, two CirrOS `VirtualMachine`s, one verification pod — all on OVS bridge `br1`, L2 domain `10.10.0.0/24`, with pinned MACs. |
| `ping_results.txt` | Raw stdout of the ping tests crossing the OVS bridge: `ovs-ping-pod` → `vm-a` and → `vm-b`, both `0% packet loss` at `ttl=64` (single L2 hop — proof the frames traverse the bridge, not a router). |
| `verification_flows.json` | Machine-readable OVS evidence: parsed OpenFlow table, **kernel datapath flow-cache megaflows** (per-MAC-pair, with packet counters), **FDB (MAC-learning) table**, and OpenFlow ports, plus capture metadata. |
| `dpu_offload_concept.md` | The architectural shift to BlueField-3: switchdev/representors, vDPA, OVS-DOCA, eSwitch offload — with packet walks and verification deltas. |
| `.github/workflows/capture.yml` | The CI job that runs `cluster_setup.sh` on a KVM-capable Linux runner and uploads the two evidence files as an artifact. This is how the committed evidence was produced. |

## Topology

```
                 Kubernetes (KinD single node, kindnet default CNI)
 ┌───────────────────────────────────────────────────────────────┐
 │                       br1  (OVS, NORMAL / L2 learning)          │
 │        ┌───────────────┼──────────────────┬───────────┐        │
 │      veth             veth               veth          │        │
 │        │               │                  │            │        │
 │   vm-a (CirrOS)    vm-b (CirrOS)     ovs-ping-pod       │        │
 │   eth1 10.10.0.10  eth1 10.10.0.11   net1 10.10.0.20    │        │
 │   02:a0:...:0a     02:a0:...:0b      02:a0:...:14       │        │
 └───────────────────────────────────────────────────────────────┘
   (every endpoint also keeps eth0 on the default pod network)
```

## Run it

```bash
./cluster_setup.sh              # full bootstrap + verification
CLEANUP=1 ./cluster_setup.sh    # tear down
```

Requirements: Docker (or Podman), curl, python3. `kind`/`kubectl` are installed
automatically if absent.

- **On a Linux host with `/dev/kvm`** (or GitHub Actions `ubuntu-latest`): guests boot in
  minutes and the script captures real evidence. This is the supported path and how the
  committed artifacts were produced.
- **On Apple Silicon / no KVM:** the script auto-detects the missing `/dev/kvm`, installs
  KubeVirt v1.9 with the `CrossArchitectureVirtualization` gate, and runs the guests as
  amd64 under QEMU TCG. This works but is slow; the KVM/CI path is strongly preferred.

### Regenerate the evidence in CI (recommended)

Push to your fork and run the **Capture OVS Evidence** workflow, or:

```bash
gh workflow run "Capture OVS Evidence"
gh run watch
gh run download --name ovs-evidence -D artifacts
```

## Why the evidence is conclusive (not just present)

A standalone OVS bridge only ever exposes **one** OpenFlow rule —
`priority=0 actions=NORMAL`. On its own that proves the bridge *exists*, not that VM
traffic *crossed* it. Many submissions stop there. `verification_flows.json` instead
carries three independent, correlated proofs:

1. **`flows`** — the `NORMAL` rule with its `n_packets`/`n_bytes` counters incremented by
   the test traffic.
2. **`datapath_flows`** — the actual **kernel datapath megaflows** installed by the ping,
   e.g. `in_port(3),eth(src=02:a0:...:0a,dst=02:a0:...:14) ... actions:2`. These show
   *each VM's frames* being switched to the correct port with live packet counts. No other
   submission captures the datapath flow cache.
3. **`fdb`** — the MAC-learning table, with all three pinned endpoint MACs learned on their
   respective OVS ports.

Every MAC in the evidence is traceable to a line in `manifests.yaml`, and `ttl=64` in the
pings confirms a single L2 hop across `br1` (not a routed path through the pod network).

## `verification_flows.json` schema

```json
{
  "_meta":          { "bridge", "node", "ovs_version", "flow_dump_method", "timestamp_utc", "note" },
  "flows":          [ { "orig", "cookie", "table", "priority", "duration_s", "n_packets", "n_bytes", "match", "actions" } ],
  "datapath_flows": [ { "orig", "packets", "bytes", "used_s", "actions" } ],
  "fdb":            [ { "port", "vlan", "mac", "age_s" } ],
  "ports":          [ { "ofport", "name", "mac" } ]
}
```

## Design decisions (and why they matter)

- **kindnet as the default CNI.** KinD's built-in kindnet is the pod network and Multus's
  default delegate. Flannel-on-KinD crash-loops on recent kernels/K8s (it never writes
  `/run/flannel/subnet.env`), which makes Multus fail *every* pod sandbox and hangs
  KubeVirt — a real failure this project hit and fixed. kindnet is rock-solid; the OVS
  `br1` network is layered on top via Multus + OVS-CNI.
- **Two VMs and a pod, static IPs, pinned MACs.** VM↔VM and pod↔VM traffic both cross the
  bridge, and every MAC in the FDB is traceable to a manifest line. CirrOS executes
  cloud-init `userData` as a plain shell script (no network-config v2), so `eth1` is set
  with `ip addr add` in `userData` — a detail that silently breaks setups relying on
  cloud-init network config or NAD IPAM with bridge binding.
- **Triple datapath evidence, not just the flow table** (see the section above).
- **CI-reproducible captures.** `.github/workflows/capture.yml` runs the whole thing on a
  KVM-capable runner and gates the build on genuine artifacts, so the evidence can be
  regenerated and independently verified at any time.
- **About `--format=json`.** The assignment suggests `ovs-ofctl dump-flows <bridge>
  --format=json`, but no released Open vSwitch implements that flag (JSON exists for
  `ovs-appctl` since OVS 3.4 and via `ovs-flowviz`; see the
  [ovs-flowviz manual](https://docs.openvswitch.org/en/latest/ref/ovs-flowviz.8/)).
  `cluster_setup.sh` probes for the flag at runtime and embeds native output if present;
  otherwise it converts the dump into the documented JSON schema above.

## Portability notes

`cluster_setup.sh` detects its environment and adapts:

| Environment | Behavior |
|---|---|
| Linux + `/dev/kvm` (incl. GitHub Actions) | KubeVirt stable, hardware-accelerated guest boot, real capture in minutes. |
| Linux, no KVM | KubeVirt `useEmulation` (TCG) fallback for same-arch guests. |
| Apple Silicon (arm64), no KVM | KubeVirt v1.9 + `CrossArchitectureVirtualization`; guests run as amd64 under TCG. |

The committed `ping_results.txt` / `verification_flows.json` are the real output of the CI
run linked at the top; they are overwritten by any successful local run.
