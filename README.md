# Assignment 2 — The Cloud-Native OVS Datapath Challenge

A containerized CirrOS VM (KubeVirt) attached to an Open vSwitch bridge through
Multus + ovs-cni on a local KinD cluster, with machine-readable datapath evidence
and a conceptual mapping to NVIDIA BlueField-3 hardware offload.

## Deliverables

| File | Content |
|---|---|
| `cluster_setup.sh` | Single executable that bootstraps everything (KinD + OVS + Flannel + Multus + ovs-cni + KubeVirt), deploys the workloads, runs the ping verification, and regenerates both evidence files. |
| `manifests.yaml` | All Custom Resources: one `NetworkAttachmentDefinition`, two CirrOS `VirtualMachine`s, one verification pod — all on OVS bridge `br1`, L2 domain `10.10.0.0/24`. |
| `ping_results.txt` | Raw stdout of the ping tests crossing the OVS bridge (pod → vm-a, pod → vm-b; echo replies prove the from-VM direction). |
| `verification_flows.json` | Machine-readable OVS evidence: parsed OpenFlow table, **datapath flow-cache entries**, **FDB (MAC learning) table**, and OpenFlow ports, plus capture metadata. |
| `dpu_offload_concept.md` | The architectural shift to BlueField-3: switchdev/representors, vDPA, OVS-DOCA, eSwitch offload — with packet walks and verification deltas. |

## Topology

```
        Kubernetes (KinD, 2 nodes, VXLAN-meshed br1)
 ┌──────────────────────────────────────────────────────┐
 │                    br1 (OVS, NORMAL)                  │
 │   ┌────────┴───────┬──────────────┴──────┐            │
 │  veth              veth                 veth          │
 │   │                 │                    │            │
 │ vm-a (CirrOS)     vm-b (CirrOS)     ovs-ping-pod      │
 │ eth1 10.10.0.10   eth1 10.10.0.11   net1 10.10.0.20   │
 │ 02:a0:00:00:00:0a 02:a0:00:00:00:0b 02:a0:00:00:00:14 │
 └──────────────────────────────────────────────────────┘
   (every endpoint also keeps eth0 on the default pod network)
```

## Run it

```bash
./cluster_setup.sh              # full bootstrap + verification (~10-20 min)
CLEANUP=1 ./cluster_setup.sh    # tear down
```

Requirements: Docker (or Podman), curl, python3. `kind`/`kubectl` are installed
automatically if absent. Best on Linux x86_64; without `/dev/kvm` the script enables
KubeVirt software emulation (TCG) automatically, and on arm64 it patches the VMs with
the `host-passthrough` CPU model that KubeVirt's admission webhook mandates there.

## Design decisions (and why they matter)

- **Two VMs and a pod, static IPs, pinned MACs.** VM↔VM and pod↔VM traffic both cross
  the bridge, and every MAC in the FDB evidence is traceable to a manifest line. CirrOS
  executes cloud-init userData as a plain shell script (it has no network-config v2
  support), so `eth1` is configured with `ip addr add` in userData — a detail that
  silently breaks IP assignment in setups that rely on cloud-init network config or NAD
  IPAM with bridge binding.
- **Two nodes with a VXLAN mesh between the per-node `br1` bridges.** The L2 domain
  survives arbitrary scheduling; single-node setups break the moment two endpoints land
  on different nodes.
- **Triple datapath evidence, not just the flow table.** A standalone OVS bridge only
  ever shows one `priority=0 actions=NORMAL` OpenFlow rule — by itself that proves the
  bridge exists, not that VM traffic crossed it. `verification_flows.json` therefore also
  captures the **datapath flow cache** (per-MAC-pair megaflows with packet counters
  installed by the ping traffic) and the **FDB** (each endpoint's MAC learned on its
  port). Together with the NORMAL rule's counters, this is conclusive.
- **About `--format=json`.** The assignment suggests `ovs-ofctl dump-flows <bridge>
  --format=json`, but no released Open vSwitch implements that flag (JSON output exists
  for `ovs-appctl` since OVS 3.4 and via `ovs-flowviz`; see the
  [ovs-flowviz manual](https://docs.openvswitch.org/en/latest/ref/ovs-flowviz.8/)).
  `cluster_setup.sh` probes for the flag at runtime and embeds native output if it ever
  appears; otherwise it converts the dump into the documented JSON schema below.
- **OVS baked into the node image.** The KinD node image is rebuilt with
  `openvswitch-switch` preinstalled instead of `apt-get install` at runtime — faster,
  cache-friendly, and identical across nodes.

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

## Generating real `ping_results.txt` and `verification_flows.json`

These two files **must** be produced by a successful `./cluster_setup.sh` run. They are
overwritten at the end of the script; do not commit hand-written or synthetic copies.

### Why this Mac cannot produce them yet

| Requirement | This Mac (arm64, no Docker) |
|---|---|
| Container runtime (Docker/Podman) | Not installed |
| KinD cluster | Needs Docker |
| KubeVirt VM boot | Needs `/dev/kvm` inside the KinD node (Mac Docker does not expose KVM) |

Without Docker you cannot start KinD. Without KVM (or very slow TCG emulation inside a
KinD node on Mac), the CirrOS guests do not boot reliably — so there is no real VM ping
to capture.

### Fix: run on a Linux host with Docker + KVM (recommended)

Use any of: a spare Linux machine, an Ubuntu VM in UTM/Parallels (enable nested
virtualization), or a cloud VM with nested virt enabled.

**1. Preflight on the Linux host**

```bash
# Must all succeed before running the script
docker info
ls -la /dev/kvm          # KVM present = VMs boot in seconds, not minutes
grep -E '(vmx|svm)' /proc/cpuinfo
free -h                  # need ~8 GB RAM free
```

**2. Copy the project and run**

```bash
# from your Mac (replace USER and HOST)
scp -r "/Users/adityasarna/lfx task 2" USER@HOST:~/opi-assignment-2/
ssh USER@HOST
cd ~/opi-assignment-2
chmod +x cluster_setup.sh
./cluster_setup.sh       # ~10–20 min with KVM; longer under emulation
```

**3. Copy the real artifacts back**

```bash
# from your Mac
scp USER@HOST:~/opi-assignment-2/ping_results.txt \
    USER@HOST:~/opi-assignment-2/verification_flows.json \
    "/Users/adityasarna/lfx task 2/"
```

**4. Verify before committing**

```bash
grep "0% packet loss" ping_results.txt          # both ping blocks must show this
python3 -c "import json; d=json.load(open('verification_flows.json')); assert d['flows'] and d['datapath_flows'] and d['fdb']"
grep parsed-from-text verification_flows.json   # should NOT appear — live capture uses real counters
```

### Alternative: install Docker on this Mac first

1. Install [Docker Desktop for Mac (Apple Silicon)](https://docs.docker.com/desktop/setup/install/mac-install/).
2. Give Docker **at least 8 GB RAM** (Settings → Resources).
3. Run `./cluster_setup.sh` locally.

Expectations on Mac **without** KVM passthrough into KinD: KubeVirt falls back to software
emulation (the script enables this automatically). Guest boot can take **30–60+ minutes**
and may still fail on arm64 due to KubeVirt admission rules. A Linux host with `/dev/kvm`
is strongly preferred for real, reproducible captures.

### Cloud VM quick start (Ubuntu 24.04)

On GCP (nested virt):

```bash
gcloud compute instances create opi-lab --zone=us-central1-a \
  --machine-type=n2-standard-8 --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud --enable-nested-virtualization
```

On the VM:

```bash
sudo apt update && sudo apt install -y docker.io git curl
sudo usermod -aG docker "$USER" && newgrp docker
# upload project, then ./cluster_setup.sh
```
