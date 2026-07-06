# How to produce / reproduce the evidence

`ping_results.txt`, `verification_flows.json`, and the `evidence/` bundle are generated
by a successful `cluster_setup.sh` run. Pick whichever path matches your machine.

## Option 1 — GitHub Actions (recommended, no local setup)

The repo ships a workflow that runs the whole stack on a GHA `ubuntu-latest` runner with
**real nested KVM** (`-accel kvm` — see `evidence/kvm_proof.txt`) and uploads the full
evidence bundle as an artifact. This is how the committed evidence was produced.

```bash
# from the repo, with the GitHub CLI authenticated
gh workflow run "Capture OVS Evidence"
gh run watch
gh run download --name ovs-evidence -D artifacts
cp artifacts/ping_results.txt artifacts/verification_flows.json .
cp -r artifacts/evidence .
```

The `Verify artifacts` step gates the build on ≥4 `0% packet loss` blocks (2 pod↔VM
+ 2 VM↔VM via `virtctl console`), a populated `verification_flows.json`, an
`evidence/` bundle, and a parser round-trip check — a green run guarantees genuine
evidence.

## Option 2 — Linux host with Docker + `/dev/kvm`

```bash
docker info                       # daemon must be running
ls -la /dev/kvm                   # present => guests boot in minutes under KVM
chmod +x cluster_setup.sh verify_datapath.sh flows_to_json.py
./cluster_setup.sh                # bootstrap + verify + capture
```

Artifacts land next to the script. Tear down with `CLEANUP=1 ./cluster_setup.sh`.

Re-run verification only (without rebuilding the cluster):

```bash
./verify_datapath.sh
```

## Option 3 — Apple Silicon / no KVM (slow, best-effort)

`cluster_setup.sh` auto-detects the missing `/dev/kvm`, installs KubeVirt v1.9 with
the `CrossArchitectureVirtualization` gate, and runs the guests as amd64 under QEMU
TCG. Give Docker Desktop ≥ 8 GB RAM. Boot can take tens of minutes; Options 1–2 are
strongly preferred for fast, reliable captures.

## Verify the artifacts locally

```bash
# 4 zero-loss blocks: pod→vm-a, pod→vm-b, vm-a→vm-b (console), vm-b→vm-a (console)
grep -c "0% packet loss" ping_results.txt        # expect 4

# JSON has 5 classifier flows, 20 datapath megaflows, 5 FDB entries
python3 -c "import json; d=json.load(open('verification_flows.json')); \
  print('flows:', len(d['flows']), 'datapath:', len(d['datapath_flows']), 'fdb:', len(d['fdb']))"

# Round-trip: raw text → parser → JSON must match committed JSON shape
python3 flows_to_json.py --bundle evidence --bridge br1 > /tmp/rt.json
python3 -c "import json; a=json.load(open('verification_flows.json')); \
  b=json.load(open('/tmp/rt.json')); \
  print('match:', len(a['flows'])==len(b['flows']), len(a['fdb'])==len(b['fdb']))"

# For a full reviewer walkthrough, see SUBMIT.md
```
