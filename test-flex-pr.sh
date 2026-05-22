#!/bin/bash
set -e

# Usage: ./test-flex-pr.sh [clean]
#
# Experiment: Kueue + ProvisioningRequest + node reuse on a Flex Start non-queued
# pool. Uses provisioningClassName: best-effort-atomic.autoscaling.x-k8s.io.
#
# Goal: discover whether this PR class preserves FSNQ's node-recycling lifecycle.
# Submits two jobs to local-queue-flex-pr (separate from the main demo queue)
# and reports:
#   • Did Kueue create a PR for each job?
#   • Did each PR reach Provisioned=True?
#   • Did job 2 land on the same node as job 1?
#   • How fast was PR #2 provisioned vs PR #1?

if [[ "${1:-}" == "clean" || "${1:-}" == "--clean" || "${1:-}" == "cleanup" ]]; then
  echo "Cleaning up test-flex-pr resources..."
  kubectl delete job job-flex-pr-1 job-flex-pr-2 --ignore-not-found=true
  kubectl get provisioningrequest -n default -o name 2>/dev/null | grep -E 'job-flex-pr-[12]' | xargs -r kubectl delete -n default --ignore-not-found=true
  echo "Done."
  exit 0
fi

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
    echo -e "  ${DIM}Manual gc:  ./test-flex-pr.sh clean${RESET}"
    return
  fi
  echo ""
  step "Cleaning up test jobs..."
  kubectl delete job job-flex-pr-1 job-flex-pr-2 --ignore-not-found=true &>/dev/null
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
    kueue.x-k8s.io/queue-name: local-queue-flex-pr
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
  local job_name="$1" label="$2"
  local pr_start; pr_start=$(date +%s)

  spin_until "${label}: workload created" \
    "kubectl get workload -n default | grep -q '${job_name}'" 60

  local wl
  wl=$(kubectl get workload -n default -o name | grep "${job_name}" | head -1 | cut -d/ -f2)
  echo -e "  ${DIM}Workload: ${wl}${RESET}"

  spin_until "${label}: ProvisioningRequest created" \
    "kubectl get provisioningrequest -n default | grep -q '${job_name}'" 60

  local pr
  pr=$(kubectl get provisioningrequest -n default -o name | grep "${job_name}" | head -1 | cut -d/ -f2)
  echo -e "  ${DIM}PR: ${pr}${RESET}"

  spin_until "${label}: PR Provisioned" \
    "kubectl get provisioningrequest ${pr} -n default -o jsonpath='{.status.conditions[?(@.type==\"Provisioned\")].status}' | grep -q True" 900

  local pr_time; pr_time=$(elapsed "${pr_start}")

  spin_until "${label}: workload admitted" \
    "kubectl get workload ${wl} -n default -o jsonpath='{.status.conditions[?(@.type==\"Admitted\")].status}' | grep -q True" 120

  local flavor
  flavor=$(kubectl get workload "${wl}" -n default \
    -o jsonpath='{.status.admission.podSetAssignments[0].flavors.cpu}' 2>/dev/null || echo unknown)
  echo -e "  ${BOLD}${ARROW} Flavor: ${BG_YELLOW}${WHITE} ${flavor} ${RESET}"

  spin_until "${label}: pod scheduled" \
    "kubectl get pods -n default -l job-name=${job_name} -o jsonpath='{.items[0].spec.nodeName}' | grep -q ." 300

  local node
  node=$(kubectl get pods -n default -l job-name="${job_name}" -o jsonpath='{.items[0].spec.nodeName}')
  echo -e "  ${BOLD}${ARROW} Node:   ${BG_YELLOW}${WHITE} ${node} ${RESET}"
  echo -e "  ${BOLD}${ARROW} PR provisioned in: ${BG_YELLOW}${WHITE} ${pr_time} ${RESET}"

  spin_until "${label}: job completed" \
    "kubectl get job ${job_name} -n default -o jsonpath='{.status.conditions[?(@.type==\"Complete\")].status}' | grep -q True" 600

  declare -g "${label}_FLAVOR=${flavor}"
  declare -g "${label}_NODE=${node}"
  declare -g "${label}_PR=${pr}"
  declare -g "${label}_PR_TIME=${pr_time}"
}

# ---------------------------------------------------------------------------
clear
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔════════════════════════════════════════════════════════════════╗"
echo "  ║  Experiment: Kueue + PR (best-effort-atomic) + reuse on FSNQ   ║"
echo "  ╚════════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${DIM}Queue:        local-queue-flex-pr${RESET}"
echo -e "  ${DIM}Flavor:       flavor-flex-pr (best-effort-atomic admission check)${RESET}"
echo -e "  ${DIM}Pool:         gpu-dws-flex-pool (--flex-start, no queued-provisioning)${RESET}"

step "Clearing any prior test workloads..."
kubectl delete job job-flex-pr-1 job-flex-pr-2 --ignore-not-found=true &>/dev/null
sleep 3

# ---------------------------------------------------------------------------
header "Job 1 — cold start (Kueue creates PR, autoscaler scales pool)"
submit_job job-flex-pr-1
ok "Submitted job-flex-pr-1"
observe_job job-flex-pr-1 JOB1

# ---------------------------------------------------------------------------
header "Brief pause — node stays warm via 'balanced' autoscaler profile"
step "Waiting 15s before submitting job 2..."
sleep 15

# ---------------------------------------------------------------------------
header "Job 2 — should produce a NEW PR; if best-effort-atomic recognizes warm capacity, PR provisions fast"
submit_job job-flex-pr-2
ok "Submitted job-flex-pr-2"
observe_job job-flex-pr-2 JOB2

# ---------------------------------------------------------------------------
header "Findings"

echo ""
echo -e "  ${BOLD}Job 1:${RESET}"
echo -e "    PR:                ${JOB1_PR}"
echo -e "    PR provisioned in: ${JOB1_PR_TIME}"
echo -e "    Node:              ${JOB1_NODE}"
echo ""
echo -e "  ${BOLD}Job 2:${RESET}"
echo -e "    PR:                ${JOB2_PR}"
echo -e "    PR provisioned in: ${JOB2_PR_TIME}"
echo -e "    Node:              ${JOB2_NODE}"
echo ""

if [[ "${JOB1_NODE}" == "${JOB2_NODE}" && -n "${JOB1_NODE}" ]]; then
  echo -e "  ${BOLD}${BG_GREEN}${WHITE}  REUSE WORKS WITH PR — same node, two PRs, both Provisioned  ${RESET}"
  echo -e "  ${DIM}best-effort-atomic does not enforce per-workload lease semantics on FSNQ.${RESET}"
else
  echo -e "  ${BOLD}${BG_RED}${WHITE}  REUSE FAILED — Job 2 on a different node (${JOB2_NODE} ≠ ${JOB1_NODE})  ${RESET}"
  echo -e "  ${DIM}best-effort-atomic likely binds capacity per-PR even on FSNQ.${RESET}"
  echo -e "  ${DIM}Compare PR provisioning times: cold (${JOB1_PR_TIME}) vs reuse attempt (${JOB2_PR_TIME}).${RESET}"
fi

echo ""
echo -e "  ${DIM}All PRs in this run:${RESET}"
kubectl get provisioningrequest -n default --no-headers 2>/dev/null | grep job-flex-pr | \
  awk '{printf "    %-50s %s\n", $1, $2}' || echo "    (none)"
echo ""
