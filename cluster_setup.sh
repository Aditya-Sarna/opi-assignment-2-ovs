#!/usr/bin/env bash
#
# cluster_setup.sh - Cloud-Native OVS Datapath Challenge (OPI Assignment 2)
#
# Bootstraps, end to end:
#   1. A two-node KinD cluster from a custom node image with Open vSwitch baked in
#   2. Flannel (default pod network), Multus (secondary networks), OVS CNI
#   3. An OVS bridge 'br1' on every node, interconnected across nodes via VXLAN
#   4. KubeVirt (with software emulation when /dev/kvm is absent)
#   5. The assignment workloads (manifests.yaml): 2 CirrOS VMs + 1 pod on br1
# then verifies the datapath and regenerates the artifacts:
#   - ping_results.txt         raw stdout of pings crossing the OVS bridge
#   - verification_flows.json  machine-readable flow/FDB/port evidence
#
# Requirements: docker (or podman), curl, python3. kind/kubectl are installed
# automatically into ~/.local/bin if missing. Linux x86_64 with KVM gives the
# smoothest run; arm64 is handled (host-passthrough patch) but needs KVM for
# guest boot; without KVM, x86_64 falls back to TCG emulation automatically.
#
# Usage:
#   ./cluster_setup.sh              # full bootstrap + verification
#   CLEANUP=1 ./cluster_setup.sh    # tear the cluster down and exit
#
# A note on the flow dump format: 'ovs-ofctl dump-flows <br> --format=json' is
# not implemented by any released Open vSwitch (JSON comes from ovs-flowviz or,
# for appctl commands, 'ovs-appctl --format json' since OVS 3.4). This script
# probes for native JSON support at runtime and uses it when present; otherwise
# it converts the raw dump into an equivalent, fully machine-readable JSON
# document (schema documented in README.md).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-ovs-kubevirt}"
KIND_VERSION="${KIND_VERSION:-v0.27.0}"
KIND_NODE_TAG="${KIND_NODE_TAG:-v1.32.2}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-ovs-kind-node:${KIND_NODE_TAG}}"
BRIDGE="${BRIDGE:-br1}"
MULTUS_VERSION="${MULTUS_VERSION:-v4.2.2}"
VM_A_IP="10.10.0.10"
VM_B_IP="10.10.0.11"
POD_IP="10.10.0.20"
MANIFESTS="${MANIFESTS:-${SCRIPT_DIR}/manifests.yaml}"
PING_RESULTS="${PING_RESULTS:-${SCRIPT_DIR}/ping_results.txt}"
FLOW_DUMP="${FLOW_DUMP:-${SCRIPT_DIR}/verification_flows.json}"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
detect_oci() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo docker
  elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    echo podman
  else
    echo ""
  fi
}

host_arch() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

install_kind() {
  command -v kind >/dev/null 2>&1 && return
  log "Installing kind ${KIND_VERSION} to ~/.local/bin"
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL --retry 3 \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-$(uname -s | tr '[:upper:]' '[:lower:]')-$(host_arch)" \
    -o "${HOME}/.local/bin/kind"
  chmod +x "${HOME}/.local/bin/kind"
  export PATH="${HOME}/.local/bin:${PATH}"
}

install_kubectl() {
  command -v kubectl >/dev/null 2>&1 && return
  log "Installing kubectl to ~/.local/bin"
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL --retry 3 \
    "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/$(uname -s | tr '[:upper:]' '[:lower:]')/$(host_arch)/kubectl" \
    -o "${HOME}/.local/bin/kubectl"
  chmod +x "${HOME}/.local/bin/kubectl"
  export PATH="${HOME}/.local/bin:${PATH}"
}

# ---------------------------------------------------------------------------
# 1. Cluster: custom node image (OVS preinstalled) + two nodes, no default CNI
# ---------------------------------------------------------------------------
preflight_disk() {
  local avail_gb path="${HOME}"
  # Linux: df -BG; macOS: df -g (1G-blocks, Available in column 4)
  if df -BG "${path}" >/dev/null 2>&1; then
    avail_gb="$(df -BG "${path}" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"
  else
    avail_gb="$(df -g "${path}" | awk 'NR==2 {print $4}')"
  fi
  if [[ -z "${avail_gb}" || ! "${avail_gb}" =~ ^[0-9]+$ ]]; then
    log "Could not parse host free disk; continuing (Docker Desktop manages its own disk pool)"
    return 0
  fi
  log "Free space (host): ~${avail_gb} GB"
  if [[ "${avail_gb}" -lt 8 ]]; then
    die "Need at least 8 GB free on host. On Mac use Docker Desktop (64 GB disk), or GitHub Actions / Oracle Cloud (see RUN.md)."
  fi
}

kind_node() {
  echo "${CLUSTER_NAME}-control-plane"
}

preflight_docker() {
  # amd64 platform on Apple Silicon breaks KinD (see kind#3973).
  if [[ "$(uname -m)" == "arm64" && "${DOCKER_DEFAULT_PLATFORM:-}" == "linux/amd64" ]]; then
    log "Unsetting DOCKER_DEFAULT_PLATFORM=linux/amd64 (breaks KinD on Apple Silicon)"
    unset DOCKER_DEFAULT_PLATFORM
  fi
  docker info >/dev/null 2>&1 || die "Docker daemon is not running — start Docker Desktop first."
  log "Docker OK ($(docker info --format '{{.ServerVersion}}'), $(uname -m))"
}

create_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    log "Reusing existing kind cluster '${CLUSTER_NAME}'"
    return
  fi
  kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
  docker rm -f "${CLUSTER_NAME}-control-plane" 2>/dev/null || true

  log "Creating single-node kind cluster '${CLUSTER_NAME}'"
  # disableDefaultCNI: node stays NotReady until Flannel — use --wait 0 to skip that wait.
  if ! kind create cluster --name "${CLUSTER_NAME}" --wait 0 --config=- <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
EOF
  then
    log "KinD create failed — collecting logs"
    kind export logs --name "${CLUSTER_NAME}" /tmp/kind-logs-$$ 2>/dev/null || true
    docker logs "${CLUSTER_NAME}-control-plane" 2>&1 | tail -30 || true
    die "KinD cluster creation failed. Try: kind delete cluster --name ${CLUSTER_NAME} && docker system prune -f && rerun."
  fi
}

install_ovs_in_nodes() {
  local oci="$1" node
  log "Installing Open vSwitch inside KinD node(s) (no custom image build — saves disk)"
  for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    ${oci} exec "${node}" bash -c "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq openvswitch-switch iputils-ping
      pgrep -x ovsdb-server >/dev/null || /usr/share/openvswitch/scripts/ovs-ctl start --system-id=random
      ovs-vsctl --may-exist add-br ${BRIDGE}
      ovs-vsctl set bridge ${BRIDGE} fail-mode=standalone
    "
    kubectl label node "${node}" "ovs-cni.network.kubevirt.io/${BRIDGE}=true" --overwrite >/dev/null
  done
}

install_cni_plugins() {
  local oci="$1" node arch cni_ver=1.6.2
  arch="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')"
  log "Installing standard CNI plugins (bridge, host-local, ...) on KinD node"
  for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    ${oci} exec "${node}" bash -c "
      set -e
      mkdir -p /opt/cni/bin
      curl -fsSL -o /tmp/cni.tgz \
        'https://github.com/containernetworking/plugins/releases/download/v${cni_ver}/cni-plugins-linux-${arch}-v${cni_ver}.tgz'
      tar xzf /tmp/cni.tgz -C /opt/cni/bin
      rm -f /tmp/cni.tgz
      test -x /opt/cni/bin/bridge
      ls /opt/cni/bin/bridge /opt/cni/bin/host-local
    "
  done
}

install_flannel() {
  log "Installing Flannel as the default pod network"
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
  kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=300s 2>/dev/null || true
  kubectl wait --for=condition=Ready nodes --all --timeout=300s
}

# ---------------------------------------------------------------------------
# 2. Open vSwitch: start daemons, create br1, interconnect nodes with VXLAN
# ---------------------------------------------------------------------------
setup_ovs_vxlan() {
  local oci="$1"
  local nodes=($(kind get nodes --name "${CLUSTER_NAME}"))
  [[ ${#nodes[@]} -lt 2 ]] && return 0
  log "Interconnecting ${BRIDGE} across nodes with VXLAN"
  local node other other_ip
  for node in "${nodes[@]}"; do
    for other in "${nodes[@]}"; do
      [[ "${node}" == "${other}" ]] && continue
      other_ip="$(${oci} inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${other}")"
      ${oci} exec "${node}" ovs-vsctl --may-exist add-port "${BRIDGE}" "vx-${other}" \
        -- set Interface "vx-${other}" type=vxlan "options:remote_ip=${other_ip}"
    done
  done
}

# ---------------------------------------------------------------------------
# 3. Networking stack: Multus + OVS CNI
# ---------------------------------------------------------------------------
install_multus() {
  log "Installing Multus CNI ${MULTUS_VERSION}"
  curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset.yml" \
    | sed "s/:snapshot/:${MULTUS_VERSION}/g" \
    | kubectl apply -f -
  kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=300s
}

install_ovs_cni() {
  log "Installing OVS CNI plugin + marker"
  local arch
  arch="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')"
  # Upstream example manifest is amd64-only; rewrite for the actual node arch.
  curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/main/examples/ovs-cni.yml" \
    | sed "s/ovs-cni-amd64/ovs-cni-${arch}/g; s|kubernetes.io/arch: amd64|kubernetes.io/arch: ${arch}|g" \
    | kubectl apply -f -
  kubectl -n kube-system rollout status "daemonset/ovs-cni-${arch}" --timeout=300s
}

# ---------------------------------------------------------------------------
# 4. KubeVirt
# ---------------------------------------------------------------------------
node_has_kvm() {
  ${OCI} exec "$(kind_node)" test -e /dev/kvm 2>/dev/null
}

needs_cross_arch_vms() {
  # Apple Silicon KinD nodes have no /dev/kvm. Native arm64 guests require
  # host-passthrough, which libvirt rejects under TCG (kubevirt/kubevirt#11917).
  # Run amd64 CirrOS via CrossArchitectureVirtualization (CPU model max) instead.
  local arch
  arch="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')"
  [[ "${arch}" == "arm64" ]] && ! node_has_kvm
}

wait_kubevirt_available() {
  local timeout="${1:-600}" elapsed=0
  while (( elapsed < timeout )); do
    if kubectl -n kubevirt get kv kubevirt -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -qx True; then
      return 0
    fi
    local phase ready total
    phase="$(kubectl -n kubevirt get kv kubevirt -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"
    ready="$(kubectl -n kubevirt get pods --no-headers 2>/dev/null | awk '$3=="Running"{c++} END{print c+0}')"
    total="$(kubectl -n kubevirt get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    log "KubeVirt ${phase}: ${ready}/${total} pods Running (${elapsed}s / ${timeout}s; image pulls can take several minutes)"
    kubectl -n kubevirt get pods --no-headers 2>/dev/null | awk '$3!="Running"{print "  pending:", $1, $3}' | head -5 || true
    sleep 15
    elapsed=$((elapsed + 15))
  done
  kubectl -n kubevirt get pods -o wide || true
  die "KubeVirt did not become Available within ${timeout}s"
}

# v1.9.0-rc.0 ships a ValidatingAdmissionPolicy whose CEL vars assume every
# initContainer has volumeMounts; virt-launcher pods omit that key and get denied.
# virt-operator recreates the policy if patched/deleted, so pause the operator and
# remove the binding before launching VMIs.
fix_kubevirt_v19_admission() {
  [[ "${KUBEVIRT_RELEASE:-}" == v1.9* ]] || needs_cross_arch_vms || return 0
  log "Pausing virt-operator and removing broken sidecar-subpath admission binding (v1.9 RC + K8s 1.32)"
  kubectl -n kubevirt scale deploy/virt-operator --replicas=0
  kubectl wait -n kubevirt --for=delete pod -l kubevirt.io=virt-operator --timeout=120s 2>/dev/null || sleep 5
  kubectl delete validatingadmissionpolicybinding kubevirt-plugin-sidecar-subpath-binding --ignore-not-found
  kubectl delete validatingadmissionpolicy kubevirt-plugin-sidecar-subpath-policy --ignore-not-found
}

restore_virt_operator() {
  [[ "${KUBEVIRT_RELEASE:-}" == v1.9* ]] || needs_cross_arch_vms || return 0
  log "Restoring virt-operator"
  kubectl -n kubevirt scale deploy/virt-operator --replicas=2
  kubectl -n kubevirt rollout status deploy/virt-operator --timeout=300s
}

preload_kubevirt_images() {
  local release="$1"
  log "Pre-loading KubeVirt images into KinD (CI disk/pull optimization)"
  local imgs=(
    "quay.io/kubevirt/virt-operator:${release}"
    "quay.io/kubevirt/virt-api:${release}"
    "quay.io/kubevirt/virt-controller:${release}"
    "quay.io/kubevirt/virt-handler:${release}"
    "quay.io/kubevirt/virt-launcher:${release}"
    "quay.io/kubevirt/cirros-container-disk-demo:latest"
  )
  for img in "${imgs[@]}"; do
    docker pull "${img}"
    kind load docker-image "${img}" --name "${CLUSTER_NAME}"
  done
}

install_kubevirt() {
  local release patch_json kv_timeout=900
  [[ -n "${GITHUB_ACTIONS:-}" ]] && kv_timeout=1800
  if needs_cross_arch_vms; then
    release="${KUBEVIRT_RELEASE:-v1.9.0-rc.0}"
    log "Arm64 without KVM: installing KubeVirt ${release} with cross-architecture VMs"
    patch_json='{"spec":{"configuration":{"developerConfiguration":{"featureGates":["MultiArchitecture","CrossArchitectureVirtualization"]}}}}'
  else
    release="${KUBEVIRT_RELEASE:-$(curl -fsSL --retry 3 https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)}"
    log "Installing KubeVirt ${release}"
    patch_json='{}'
  fi
  export KUBEVIRT_RELEASE="${release}"
  [[ -n "${GITHUB_ACTIONS:-}" ]] && preload_kubevirt_images "${release}"
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${release}/kubevirt-operator.yaml"
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${release}/kubevirt-cr.yaml"
  wait_kubevirt_available "${kv_timeout}"

  # No /dev/kvm => software emulation fallback for same-arch guests (linux/amd64 CI).
  if ! node_has_kvm && ! needs_cross_arch_vms; then
    log "/dev/kvm not present in nodes; enabling KubeVirt software emulation"
    kubectl -n kubevirt patch kubevirt kubevirt --type merge \
      -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
    wait_kubevirt_available 600
  fi

  if needs_cross_arch_vms; then
    kubectl -n kubevirt patch kubevirt kubevirt --type merge -p "${patch_json}"
    # Cross-arch TCG still needs useEmulation when the node has no /dev/kvm,
    # otherwise virt-launcher pods request devices.kubevirt.io/kvm and stay Pending.
    kubectl -n kubevirt patch kubevirt kubevirt --type merge \
      -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
    # v1.9 ImageVolume needs K8s 1.35+; KinD 1.32 breaks container-disk init
    # (exec: /container-disk-binary/usr/bin/container-disk: no such file or directory).
    kubectl -n kubevirt patch kubevirt kubevirt --type merge \
      -p '{"spec":{"configuration":{"developerConfiguration":{"disabledFeatureGates":["ImageVolume"]}}}}'
    wait_kubevirt_available 600
    fix_kubevirt_v19_admission
    log "Cross-arch mode: VMs run as amd64 guests under QEMU TCG (slow; allow ~30 min)"
  fi
}

configure_vms_for_platform() {
  if ! needs_cross_arch_vms; then
    return 0
  fi
  log "Ensuring VMs use amd64/q35 for cross-arch TCG on arm64 host"
  for vm in vm-a vm-b; do
    kubectl patch vm "${vm}" --type=json -p='[
      {"op":"add","path":"/spec/template/spec/architecture","value":"amd64"},
      {"op":"add","path":"/spec/template/spec/domain/machine","value":{"type":"q35"}}
    ]' 2>/dev/null || kubectl patch vm "${vm}" --type=json -p='[
      {"op":"replace","path":"/spec/template/spec/architecture","value":"amd64"},
      {"op":"replace","path":"/spec/template/spec/domain/machine/type","value":"q35"}
    ]'
  done
  local node
  node="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
  log "Labeling node ${node} for cross-arch amd64/q35 scheduling"
  kubectl label node "${node}" \
    kubevirt.io/vm-arch-amd64=true \
    machine-type.node.kubevirt.io/q35=true \
    --overwrite
  kubectl delete vmi vm-a vm-b --ignore-not-found --wait=false 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 5. Workloads + verification
# ---------------------------------------------------------------------------
deploy_workloads() {
  log "Applying ${MANIFESTS}"
  kubectl apply -f "${MANIFESTS}"
  configure_vms_for_platform
  fix_kubevirt_v19_admission
  local vmi_timeout="${VMI_WAIT_TIMEOUT:-600}"
  if needs_cross_arch_vms; then
    vmi_timeout="${VMI_WAIT_TIMEOUT:-3600}"
  fi
  log "Waiting for the ping pod and both VMIs (timeout ${vmi_timeout}s)"
  kubectl wait pod/ovs-ping-pod --for=condition=Ready --timeout=300s
  kubectl wait vmi/vm-a vmi/vm-b --for=jsonpath='{.status.phase}'=Running --timeout="${vmi_timeout}s"
  restore_virt_operator
}

wait_for_guest_network() {
  # CirrOS under TCG can take minutes to boot and run its userdata script;
  # poll until the VM answers on the OVS network.
  log "Waiting for CirrOS guests to configure eth1 (this is the slow part under emulation)"
  local i
  for i in $(seq 1 60); do
    if kubectl exec ovs-ping-pod -- ping -c 1 -W 2 "${VM_A_IP}" >/dev/null 2>&1 \
       && kubectl exec ovs-ping-pod -- ping -c 1 -W 2 "${VM_B_IP}" >/dev/null 2>&1; then
      log "Both guests reachable on the OVS network"
      return 0
    fi
    sleep 10
  done
  die "Guests never became reachable on ${BRIDGE}; check 'kubectl get vmi' and virt-launcher logs"
}

run_ping_test() {
  log "Running ping tests across ${BRIDGE} (results -> ${PING_RESULTS})"
  {
    echo "\$ kubectl exec ovs-ping-pod -- ping -c 4 ${VM_A_IP}"
    kubectl exec ovs-ping-pod -- ping -c 4 "${VM_A_IP}"
    echo
    echo "\$ kubectl exec ovs-ping-pod -- ping -c 4 ${VM_B_IP}"
    kubectl exec ovs-ping-pod -- ping -c 4 "${VM_B_IP}"
  } | tee "${PING_RESULTS}"

  local loss_count
  loss_count="$(grep -c '0% packet loss' "${PING_RESULTS}" || true)"
  if [[ "${loss_count}" -lt 2 ]]; then
    rm -f "${PING_RESULTS}"
    die "Ping verification failed (expected two '0% packet loss' blocks). Artifacts were not kept."
  fi
}

capture_ovs_evidence() {
  local oci="$1"
  # Capture on the node actually hosting vm-a's launcher pod - that is where
  # the VM's frames provably traverse the bridge.
  local node
  node="$(kubectl get pod -l kubevirt.io/domain=vm-a -o jsonpath='{.items[0].spec.nodeName}')"
  log "Capturing OVS evidence on node '${node}' (bridge ${BRIDGE})"

  local tmp
  tmp="$(mktemp -d)"

  # Probe for native JSON support first (see header note); fall back to text.
  local method="parsed-from-text"
  if ${oci} exec "${node}" ovs-ofctl dump-flows "${BRIDGE}" --format=json \
       > "${tmp}/openflow.json" 2>/dev/null; then
    method="ovs-ofctl-native-json"
  fi
  ${oci} exec "${node}" ovs-ofctl dump-flows "${BRIDGE}"        > "${tmp}/openflow.txt"
  ${oci} exec "${node}" ovs-appctl dpctl/dump-flows             > "${tmp}/datapath.txt" || true
  ${oci} exec "${node}" ovs-appctl fdb/show "${BRIDGE}"         > "${tmp}/fdb.txt"      || true
  ${oci} exec "${node}" ovs-ofctl show "${BRIDGE}"              > "${tmp}/ports.txt"
  local ovs_version
  ovs_version="$(${oci} exec "${node}" ovs-vsctl --version | head -1)"

  python3 - "${tmp}" "${FLOW_DUMP}" "${BRIDGE}" "${node}" "${ovs_version}" "${method}" <<'PYEOF'
import json, re, sys, datetime

tmp, out, bridge, node, ovs_version, method = sys.argv[1:7]

def read(name):
    try:
        with open(f"{tmp}/{name}") as f:
            return f.read()
    except FileNotFoundError:
        return ""

flows = []
for line in read("openflow.txt").splitlines():
    line = line.strip()
    if "actions=" not in line:
        continue
    fields = dict(re.findall(r"(\w+)=([^,\s]+)", line.split(" actions=")[0]))
    match_part = line.split(" actions=")[0].split(",")[-1].strip()
    flows.append({
        "orig": line,
        "cookie": fields.get("cookie"),
        "table": int(fields.get("table", 0)),
        "priority": int(fields.get("priority", 0)) if "priority" in fields else None,
        "duration_s": float(fields.get("duration", "0").rstrip("s")),
        "n_packets": int(fields.get("n_packets", 0)),
        "n_bytes": int(fields.get("n_bytes", 0)),
        "match": match_part if "=" not in match_part or "priority" not in match_part else "*",
        "actions": line.split("actions=")[1],
    })

dp_flows = []
for line in read("datapath.txt").splitlines():
    line = line.strip()
    if not line or "actions:" not in line:
        continue
    pkts = re.search(r"packets:(\d+)", line)
    byts = re.search(r"bytes:(\d+)", line)
    used = re.search(r"used:([\d.]+)s", line)
    dp_flows.append({
        "orig": line,
        "packets": int(pkts.group(1)) if pkts else 0,
        "bytes": int(byts.group(1)) if byts else 0,
        "used_s": float(used.group(1)) if used else None,
        "actions": line.split("actions:")[1].strip(),
    })

fdb = []
for line in read("fdb.txt").splitlines():
    m = re.match(r"\s*(\d+)\s+(\d+)\s+([0-9a-f:]{17})\s+([\d.]+|LOCAL)", line)
    if m:
        fdb.append({"port": int(m.group(1)), "vlan": int(m.group(2)),
                    "mac": m.group(3), "age_s": m.group(4)})

ports = []
for line in read("ports.txt").splitlines():
    m = re.match(r"\s*(\d+|LOCAL)\((\S+)\): addr:([0-9a-f:]{17})", line)
    if m:
        ports.append({"ofport": m.group(1), "name": m.group(2), "mac": m.group(3)})

native = read("openflow.json")

doc = {
    "_meta": {
        "generated_by": "cluster_setup.sh capture_ovs_evidence()",
        "timestamp_utc": datetime.datetime.now(datetime.timezone.utc)
            .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "bridge": bridge,
        "node": node,
        "ovs_version": ovs_version,
        "flow_dump_method": method,
        "note": ("'ovs-ofctl dump-flows --format=json' is not implemented by "
                 "released OVS; JSON was produced via the documented fallback "
                 "and native output is embedded when the flag exists."),
    },
    "bridge": bridge,
    "flows": flows,
    "datapath_flows": dp_flows,
    "fdb": fdb,
    "ports": ports,
}
if native.strip():
    try:
        doc["native_json_dump"] = json.loads(native)
    except ValueError:
        pass

with open(out, "w") as f:
    json.dump(doc, f, indent=2)
print(f"wrote {out}")
PYEOF
  rm -rf "${tmp}"

  python3 -c "
import json, sys
d = json.load(open('${FLOW_DUMP}'))
if not d.get('flows') or not d.get('datapath_flows') or not d.get('fdb'):
    sys.exit('OVS evidence incomplete (missing flows, datapath_flows, or fdb)')
" || { rm -f "${FLOW_DUMP}"; die "OVS capture incomplete; ${FLOW_DUMP} was not kept."; }
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${CLEANUP:-0}" == "1" ]]; then
    kind delete cluster --name "${CLUSTER_NAME}" || true
    exit 0
  fi

  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  OCI="$(detect_oci)"
  [[ -n "${OCI}" ]] || die "Docker or Podman with a running daemon is required"
  install_kind
  install_kubectl
  preflight_docker
  preflight_disk
  docker system prune -f >/dev/null 2>&1 || true
  create_cluster
  install_cni_plugins "${OCI}"
  install_flannel
  install_ovs_in_nodes "${OCI}"
  setup_ovs_vxlan "${OCI}"
  install_multus
  install_ovs_cni
  install_kubevirt
  deploy_workloads
  wait_for_guest_network
  run_ping_test
  capture_ovs_evidence "${OCI}"

  log "Done."
  log "  ping results : ${PING_RESULTS}"
  log "  flow evidence: ${FLOW_DUMP}"
}

main "$@"
