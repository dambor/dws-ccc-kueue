#!/bin/bash
set -e

# Usage: ./test-reuse.sh [clean]
#   (no args) → submit two jobs back-to-back on the non-queued Flex pool;
#               verify that job 2 lands on the SAME node as job 1 (reuse).
#   clean    → delete leftover jobs/workloads/PRs and exit.
#
# Why this test targets flavor-flex specifically:
#   GKE Flex Start has two modes:
#     • non-queued (--flex-start)              → nodes RECYCLED across workloads ✔
#     • queued    (--flex-start --enable-queued-provisioning) → no reuse, PR-per-workload
#   This script forces pods onto pool-type=flex via nodeSelector to demo reuse.

if [[ "${1:-}" == "clean" || "${1:-}" == "--clean" || "${1:-}" == "cleanup" ]]; then
  echo "Cleaning up test-reuse resources..."
  kubectl delete job job-reuse-1 job-reuse-2 --ignore-not-found=true
  kubectl get provisioningrequest -n default -o name 2>/dev/null | grep -E 'job-reuse-[12]' | xargs -r kubectl delete -n default --ignore-not-found=true
  echo "Done."
  exit 0
fi

RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"
GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; RED="\033[31m"; WHITE="\033[97m"
BG_BLUE="\033[44m"; BG_GREEN="\033[42m"; BG_RED="\033[41m"; BG_YELLOW="\033[43m"

CHECK="${GREEN}✔${RESET}"
CROSS="${RED}✖${RESET}"
ARROW="${CYAN}➜${RESET}"
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
    warn "Script failed (exit $rc) — leaving jobs/workloads in place for diagnostics."
    echo -e "  ${DIM}Inspect:    kubectl get workload,job,pod -n default${RESET}"
    echo -e "  ${DIM}Manual gc:  ./test-reuse.sh clean${RESET}"
    return
  fi
  echo ""
  step "Cleaning up test jobs..."
  kubectl delete job job-reuse-1 job-reuse-2 --ignore-not-found=true &>/dev/null
}
trap cleanup EXIT

submit_job() {
  local name="$1"
  cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: default
  labels:
    kueue.x-k8s.io/queue-name: local-queue-dws
spec:
  parallelism: 1
  completions: 1
  template:
    spec:
      nodeSelector:
        pool-type: flex
      containers:
      - name: dummy-ml-workload
        image: ubuntu
        command: ["sleep", "60"]
        resources:
          requests:
            cpu: "1"
            memory: "1Gi"
            nvidia.com/gpu: "1"
          limits:
            nvidia.com/gpu: "1"
      tolerations:
      - key: cloud.google.com/gke-flex-start
        operator: Equal
        value: "true"
        effect: NoSchedule
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      restartPolicy: Never
EOF
}

observe_job() {
  local job_name="$1" label="$2" admit_timeout="${3:-900}"

  spin_until "${label}: workload created" \
    "kubectl get workload -n default | grep -q '${job_name}'" 60

  local wl
  wl=$(kubectl get workload -n default -o name | grep "${job_name}" | head -1 | cut -d/ -f2)
  echo -e "  ${DIM}Workload: ${wl}${RESET}"

  spin_until "${label}: workload admitted" \
    "kubectl get workload ${wl} -n default -o jsonpath='{.status.conditions[?(@.type==\"Admitted\")].status}' | grep -q True" 180

  local flavor
  flavor=$(kubectl get workload "${wl}" -n default \
    -o jsonpath='{.status.admission.podSetAssignments[0].flavors.cpu}' 2>/dev/null || echo unknown)
  echo -e "  ${BOLD}${ARROW} Flavor admitted: ${BG_YELLOW}${WHITE} ${flavor} ${RESET}"

  spin_until "${label}: pod scheduled to a node" \
    "kubectl get pods -n default -l job-name=${job_name} -o jsonpath='{.items[0].spec.nodeName}' | grep -q ." "${admit_timeout}"

  local node
  node=$(kubectl get pods -n default -l job-name="${job_name}" \
    -o jsonpath='{.items[0].spec.nodeName}')
  echo -e "  ${BOLD}${ARROW} Pod node:        ${BG_YELLOW}${WHITE} ${node} ${RESET}"

  spin_until "${label}: job completed" \
    "kubectl get job ${job_name} -n default -o jsonpath='{.status.conditions[?(@.type==\"Complete\")].status}' | grep -q True" 600

  declare -g "${label}_FLAVOR=${flavor}"
  declare -g "${label}_NODE=${node}"
}

# ---------------------------------------------------------------------------
clear
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║   Experiment: warm node reuse on DWS Flex (non-queued)   ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${DIM}Both jobs target pool-type=flex (DWS Flex Start non-queued).${RESET}"
echo -e "  ${DIM}GKE docs: 'Flex-start supports node recycling, while Flex-start${RESET}"
echo -e "  ${DIM}with queued provisioning does not.'${RESET}"

step "Clearing any prior test workloads..."
kubectl delete job job-reuse-1 job-reuse-2 --ignore-not-found=true &>/dev/null
sleep 3

# ---------------------------------------------------------------------------
header "Job 1 — cold start on Flex pool (provisions a new node)"
submit_job job-reuse-1
ok "Submitted job-reuse-1"
observe_job job-reuse-1 JOB1

# ---------------------------------------------------------------------------
header "Brief pause — node stays warm via 'balanced' autoscaling profile (~10 min idle)"
step "Waiting 15s before submitting job 2..."
sleep 15

# ---------------------------------------------------------------------------
header "Job 2 — should land on the SAME node (reuse)"
submit_job job-reuse-2
ok "Submitted job-reuse-2"
observe_job job-reuse-2 JOB2 300

# ---------------------------------------------------------------------------
header "Findings"

echo ""
echo -e "  ${BOLD}Job 1:${RESET}"
echo -e "    Flavor:  ${JOB1_FLAVOR}"
echo -e "    Node:    ${JOB1_NODE}"
echo ""
echo -e "  ${BOLD}Job 2:${RESET}"
echo -e "    Flavor:  ${JOB2_FLAVOR}"
echo -e "    Node:    ${JOB2_NODE}"
echo ""

if [[ "${JOB1_NODE}" == "${JOB2_NODE}" && -n "${JOB1_NODE}" ]]; then
  echo -e "  ${BOLD}${BG_GREEN}${WHITE}  REUSE WORKS — Job 2 ran on the same node as Job 1  ${RESET}"
else
  echo -e "  ${BOLD}${BG_RED}${WHITE}  REUSE FAILED — Job 2 got a different node (${JOB2_NODE} ≠ ${JOB1_NODE})  ${RESET}"
  echo -e "  ${DIM}Check: did the autoscaler scale down job 1's node before job 2 arrived?${RESET}"
  echo -e "  ${DIM}Check: --autoscaling-profile=balanced should give ~10 min idle window.${RESET}"
fi

echo ""
echo -e "  ${DIM}Cluster nodes in the flex pool:${RESET}"
kubectl get nodes -l pool-type=flex --no-headers 2>/dev/null | \
  awk '{printf "    %s   age: %s\n", $1, $4}' || echo "    (none)"
echo ""
