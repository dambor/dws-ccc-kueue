#!/bin/bash
set -e

# Usage: ./test-tas-reuse.sh [dedicated|clean]
#
#   (no args)   Phase 1 + 2:  cold start (PR + atomic scale-up) → warm reuse
#                             (no PR, same node) via the TAS flavor fallback.
#   dedicated   Also run Phase 3: a job that OMITS the gke-queued toleration,
#                             forcing a fresh dedicated PR scale-up instead of
#                             reusing the warm node. Needs gpu-dws-pool max>=2.
#   clean       Delete leftover jobs / workloads / PRs and exit.
#
# Scenario: "Stop Trashing Nodes" — combining DWS atomic (queued) provisioning
# with node reuse using a TAS-enabled flavor fallback in Kueue.
#   • cluster-queue-tas has two flavors on the SAME pool (gpu-dws-pool):
#       regular-flavor (no check)  → reuse warm nodes instantly, no PR
#       dws-flavor    (PR check)   → cold-start atomic DWS scale-up
#   • Both flavors are TAS-enabled, so the queue is TAS-only and Kueue implies
#     TAS for every job (no topology annotation needed).
#   • A job's cloud.google.com/gke-queued toleration is the opt-in to reuse:
#     with it, TAS counts the warm queued node; without it, the node's taint is
#     untolerated, regular-flavor fails, and the job falls back to dws-flavor.

if [[ "${1:-}" == "clean" || "${1:-}" == "--clean" || "${1:-}" == "cleanup" ]]; then
  echo "Cleaning up test-tas-reuse resources..."
  kubectl delete job job-tas-1 job-tas-2 job-tas-3 --ignore-not-found=true
  kubectl get provisioningrequest -n default -o name 2>/dev/null | grep -E 'job-tas-[123]' | xargs -r kubectl delete -n default --ignore-not-found=true
  echo "Done."
  exit 0
fi

WITH_DEDICATED=false
[[ "${1:-}" == "dedicated" || "${1:-}" == "--with-dedicated" ]] && WITH_DEDICATED=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAS_CONFIG="${SCRIPT_DIR}/kueue-config-tas.yaml"

RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"
GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; RED="\033[31m"; WHITE="\033[97m"
BG_BLUE="\033[44m"; BG_GREEN="\033[42m"; BG_RED="\033[41m"; BG_YELLOW="\033[43m"

CHECK="${GREEN}✔${RESET}"; CROSS="${RED}✖${RESET}"; ARROW="${CYAN}➜${RESET}"
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

header() {
  echo ""
  echo -e "${BOLD}${BG_BLUE}${WHITE}  $1  ${RESET}"
  echo -e "${DIM}────────────────────────────────────────────────────────${RESET}"
}
step() { echo -e "  ${ARROW} $1"; }
ok()   { echo -e "  ${CHECK} ${GREEN}$1${RESET}"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  ${YELLOW}$1${RESET}"; }
fail() { echo -e "  ${CROSS} ${RED}$1${RESET}"; exit 1; }
elapsed() { echo $(( $(date +%s) - $1 ))s; }

spin_until() {
  local label="$1" cmd="$2" timeout="${3:-300}" i=0
  local start; start=$(date +%s)
  while ! eval "${cmd}" &>/dev/null; do
    local frame="${SPINNER_FRAMES[$((i % ${#SPINNER_FRAMES[@]}))]}"
    printf "\r  ${YELLOW}${frame}${RESET}  %s  ${DIM}(%ss)${RESET}" "${label}" "$(elapsed "${start}")"
    sleep 0.5; i=$(( i + 1 ))
    if (( $(date +%s) - start > timeout )); then
      printf "\r"; fail "Timeout after ${timeout}s: ${label}"
    fi
  done
  printf "\r"
  ok "${label}  ${DIM}($(elapsed "${start}"))${RESET}"
}

cleanup() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo ""
    warn "Script failed (exit $rc) — leaving resources in place for diagnostics."
    echo -e "  ${DIM}Inspect:    kubectl get workload,provisioningrequest,job -n default${RESET}"
    echo -e "  ${DIM}Manual gc:  ./test-tas-reuse.sh clean${RESET}"
    return
  fi
  echo ""
  step "Cleaning up test jobs..."
  kubectl delete job job-tas-1 job-tas-2 job-tas-3 --ignore-not-found=true &>/dev/null
}
trap cleanup EXIT

# Preflight: make the script self-contained so it can be run on a fresh machine.
#   1) cluster reachable   2) Kueue + TAS/v1beta2 present   3) apply TAS config
#   4) wait for the queue to go Active
preflight() {
  header "Preflight"

  step "Checking cluster connectivity..."
  if ! kubectl cluster-info &>/dev/null; then
    fail "kubectl can't reach a cluster. Point your context at the GKE cluster first:
       gcloud container clusters get-credentials <cluster> --location <region> --project <project>"
  fi
  ok "Cluster reachable  ${DIM}($(kubectl config current-context 2>/dev/null))${RESET}"

  step "Checking Kueue + Topology Aware Scheduling support..."
  if ! kubectl get crd topologies.kueue.x-k8s.io &>/dev/null; then
    fail "Topology CRD (topologies.kueue.x-k8s.io) not found — Kueue is missing or older than v0.14.
       Install/upgrade Kueue >= v0.18.0:  KUEUE_VERSION=v0.18.0 ./deploy.sh"
  fi
  local kver
  kver=$(kubectl get deploy kueue-controller-manager -n kueue-system \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')
  ok "Kueue present ${DIM}(${kver:-unknown})${RESET}, TAS available"

  step "Applying TAS config (kueue-config-tas.yaml)..."
  if [[ ! -f "${TAS_CONFIG}" ]]; then
    fail "Can't find ${TAS_CONFIG} — run this script from inside the repo checkout."
  fi
  kubectl apply -f "${TAS_CONFIG}" >/dev/null
  ok "Applied Topology, regular-flavor/dws-flavor, PRC, admission check, cluster-queue-tas, local-queue-tas"

  spin_until "cluster-queue-tas active" \
    "kubectl get clusterqueue cluster-queue-tas -o jsonpath='{.status.conditions[?(@.type==\"Active\")].status}' | grep -q True" 60
  spin_until "local-queue-tas active" \
    "kubectl get localqueue local-queue-tas -n default -o jsonpath='{.status.conditions[?(@.type==\"Active\")].status}' | grep -q True" 60

  # The queued pool can sit at 0 nodes; we can't list it via Node objects then.
  # Just remind about capacity for the optional dedicated phase.
  if [[ "${WITH_DEDICATED}" == "true" ]]; then
    warn "Dedicated phase needs gpu-dws-pool total-max-nodes >= 2 (cold node + a fresh dedicated node)."
    warn "deploy.sh sets it to 3. If your pool is older/smaller, bump it:"
    echo -e "  ${DIM}gcloud container clusters update <cluster> --location <region> \\\\${RESET}"
    echo -e "  ${DIM}  --node-pool gpu-dws-pool --enable-autoscaling --total-max-nodes 3${RESET}"
  fi
}

# submit_job <name> <reuse:true|false>
#   reuse=true  → include cloud.google.com/gke-queued toleration (opt in to reuse)
#   reuse=false → omit it (force a dedicated dws-flavor scale-up)
submit_job() {
  local name="$1" reuse="$2"
  local queued_tol=""
  if [[ "${reuse}" == "true" ]]; then
    queued_tol=$'      - key: cloud.google.com/gke-queued\n        operator: Exists\n        effect: NoSchedule'
  fi
  cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: default
  labels:
    kueue.x-k8s.io/queue-name: local-queue-tas
spec:
  parallelism: 1
  completions: 1
  template:
    spec:
      nodeSelector:
        cloud.google.com/gke-nodepool: gpu-dws-pool
      containers:
      - name: dummy-ml-workload
        image: registry.k8s.io/e2e-test-images/agnhost:2.53
        args: ["pause"]
        resources:
          requests:
            cpu: "1"
            memory: "1Gi"
            nvidia.com/gpu: "1"
          limits:
            nvidia.com/gpu: "1"
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
${queued_tol}
      restartPolicy: Never
EOF
}

# observe_job <job_name> <label> [expect_pr:true|false]
observe_job() {
  local job_name="$1" label="$2" expect_pr="${3:-true}"
  local t0; t0=$(date +%s)

  spin_until "${label}: workload created" \
    "kubectl get workload -n default | grep -q '${job_name}'" 60
  local wl
  wl=$(kubectl get workload -n default -o name | grep "${job_name}" | head -1 | cut -d/ -f2)
  echo -e "  ${DIM}Workload: ${wl}${RESET}"

  spin_until "${label}: workload admitted" \
    "kubectl get workload ${wl} -n default -o jsonpath='{.status.conditions[?(@.type==\"Admitted\")].status}' | grep -q True" 900

  local flavor
  flavor=$(kubectl get workload "${wl}" -n default \
    -o jsonpath='{.status.admission.podSetAssignments[0].flavors.cpu}' 2>/dev/null || echo unknown)
  echo -e "  ${BOLD}${ARROW} Flavor:  ${BG_YELLOW}${WHITE} ${flavor} ${RESET}"

  # Did Kueue create a ProvisioningRequest for this job?
  local pr
  pr=$(kubectl get provisioningrequest -n default -o name 2>/dev/null | grep "${job_name}" | head -1 | cut -d/ -f2 || true)
  if [[ -n "${pr}" ]]; then
    echo -e "  ${BOLD}${ARROW} PR:      ${BG_YELLOW}${WHITE} ${pr} ${RESET}"
  else
    echo -e "  ${BOLD}${ARROW} PR:      ${BG_GREEN}${WHITE} none — admitted without provisioning ${RESET}"
  fi

  spin_until "${label}: pod scheduled" \
    "kubectl get pods -n default -l job-name=${job_name} -o jsonpath='{.items[0].spec.nodeName}' | grep -q ." 300
  local node
  node=$(kubectl get pods -n default -l job-name="${job_name}" -o jsonpath='{.items[0].spec.nodeName}')
  echo -e "  ${BOLD}${ARROW} Node:    ${BG_YELLOW}${WHITE} ${node} ${RESET}"
  echo -e "  ${BOLD}${ARROW} Admitted in: ${BG_YELLOW}${WHITE} $(elapsed "${t0}") ${RESET}"

  declare -g "${label}_FLAVOR=${flavor}"
  declare -g "${label}_NODE=${node}"
  declare -g "${label}_PR=${pr}"
}

# ---------------------------------------------------------------------------
clear
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔════════════════════════════════════════════════════════════════╗"
echo "  ║  Atomic DWS provisioning + node reuse via TAS flavor fallback   ║"
echo "  ╚════════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${DIM}Queue:    local-queue-tas  (regular-flavor → dws-flavor fallback)${RESET}"
echo -e "  ${DIM}Pool:     gpu-dws-pool  (--enable-queued-provisioning, atomic)${RESET}"
echo -e "  ${DIM}Reuse:    job carries cloud.google.com/gke-queued toleration${RESET}"

preflight

step "Clearing any prior test workloads..."
kubectl delete job job-tas-1 job-tas-2 job-tas-3 --ignore-not-found=true &>/dev/null
sleep 3

# ---------------------------------------------------------------------------
header "Job 1 — cold start (TAS finds no node → dws-flavor → PR → atomic scale-up)"
step "Expect: flavor=dws-flavor, a ProvisioningRequest, and (briefly) a"
step "SecondPassFailed warning while the new node syncs to Kueue's TAS cache."
submit_job job-tas-1 true
ok "Submitted job-tas-1 (reuse opt-in)"
observe_job job-tas-1 JOB1 true

step "Waiting for job-tas-1 to finish so its GPU frees up (node stays warm)..."
spin_until "job-tas-1 completed" \
  "kubectl get job job-tas-1 -n default -o jsonpath='{.status.conditions[?(@.type==\"Complete\")].status}' | grep -q True" 600

# ---------------------------------------------------------------------------
header "Job 2 — warm reuse (TAS finds the idle node → regular-flavor → NO PR)"
step "Node is warm and idle; submitting immediately..."
sleep 5
submit_job job-tas-2 true
ok "Submitted job-tas-2 (reuse opt-in)"
observe_job job-tas-2 JOB2 false

# ---------------------------------------------------------------------------
if [[ "${WITH_DEDICATED}" == "true" ]]; then
  spin_until "job-tas-2 completed" \
    "kubectl get job job-tas-2 -n default -o jsonpath='{.status.conditions[?(@.type==\"Complete\")].status}' | grep -q True" 600
  header "Job 3 — dedicated (NO gke-queued toleration → can't reuse → fresh PR)"
  step "Without the toleration, TAS excludes the warm node (untolerated taint),"
  step "regular-flavor fails, and the job falls back to dws-flavor for a new node."
  submit_job job-tas-3 false
  ok "Submitted job-tas-3 (reuse opt-OUT)"
  observe_job job-tas-3 JOB3 true
fi

# ---------------------------------------------------------------------------
header "Findings"
echo ""
echo -e "  ${BOLD}Job 1 (cold):${RESET}    flavor=${JOB1_FLAVOR}  pr=${JOB1_PR:-none}  node=${JOB1_NODE}"
echo -e "  ${BOLD}Job 2 (reuse):${RESET}   flavor=${JOB2_FLAVOR}  pr=${JOB2_PR:-none}  node=${JOB2_NODE}"
[[ "${WITH_DEDICATED}" == "true" ]] && \
echo -e "  ${BOLD}Job 3 (dedic):${RESET}   flavor=${JOB3_FLAVOR}  pr=${JOB3_PR:-none}  node=${JOB3_NODE}"
echo ""

reuse_ok=true
[[ "${JOB2_NODE}" == "${JOB1_NODE}" && -n "${JOB1_NODE}" ]] || reuse_ok=false
[[ -z "${JOB2_PR}" ]] || reuse_ok=false
[[ "${JOB2_FLAVOR}" == "regular-flavor" ]] || reuse_ok=false

if [[ "${reuse_ok}" == "true" ]]; then
  echo -e "  ${BOLD}${BG_GREEN}${WHITE}  REUSE WORKS — Job 2 reused Job 1's node via regular-flavor, no new PR  ${RESET}"
  echo -e "  ${DIM}Atomic provisioning on cold start, instant reuse on warm capacity.${RESET}"
else
  echo -e "  ${BOLD}${BG_RED}${WHITE}  REUSE NOT OBSERVED  ${RESET}"
  [[ "${JOB2_NODE}" != "${JOB1_NODE}" ]] && echo -e "  ${DIM}Job 2 landed on a different node (${JOB2_NODE} ≠ ${JOB1_NODE}).${RESET}"
  [[ -n "${JOB2_PR}" ]]                  && echo -e "  ${DIM}Job 2 created a PR (${JOB2_PR}) — TAS didn't see the warm node in time.${RESET}"
  [[ "${JOB2_FLAVOR}" != "regular-flavor" ]] && echo -e "  ${DIM}Job 2 admitted via ${JOB2_FLAVOR}, not regular-flavor.${RESET}"
  echo -e "  ${DIM}If the node scaled down before Job 2, re-check the CA idle timeout.${RESET}"
fi

if [[ "${WITH_DEDICATED}" == "true" ]]; then
  echo ""
  if [[ -n "${JOB3_PR}" && "${JOB3_NODE}" != "${JOB1_NODE}" ]]; then
    echo -e "  ${BOLD}${BG_GREEN}${WHITE}  OPT-OUT WORKS — Job 3 got a fresh dedicated PR + node  ${RESET}"
  else
    echo -e "  ${BOLD}${BG_YELLOW}${WHITE}  Job 3 did not get a dedicated node as expected (pr=${JOB3_PR:-none}, node=${JOB3_NODE})  ${RESET}"
  fi
fi

echo ""
echo -e "  ${DIM}ProvisioningRequests this run:${RESET}"
kubectl get provisioningrequest -n default --no-headers 2>/dev/null | grep job-tas | \
  awk '{printf "    %-55s %s\n", $1, $2}' || echo "    (none)"
echo ""
echo -e "  ${DIM}Nodes in gpu-dws-pool:${RESET}"
kubectl get nodes -l cloud.google.com/gke-nodepool=gpu-dws-pool --no-headers 2>/dev/null | \
  awk '{printf "    %s   age: %s\n", $1, $4}' || echo "    (none)"
echo ""
