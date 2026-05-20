#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# Experiment: warm-node reuse via check-capacity admission check
#
# Hypothesis: with two ResourceFlavors on the same DWS pool —
#   flavor-flex-warm  (check-capacity admission)
#   flavor-ondemand   (queued-provisioning admission)
# — Kueue should admit a *second* job (submitted while the first job's node
# is still warm) to flavor-flex-warm, avoiding a new ProvisioningRequest.
#
# This script submits two jobs sequentially and reports:
#   • which flavor admitted each
#   • which node each ran on (same node = reuse worked)
#   • whether a new ProvisioningRequest was created for the second job
# ---------------------------------------------------------------------------

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
        pool-type: ondemand
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
      - key: cloud.google.com/gke-queued
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
  local job_name="$1" label="$2" pr_timeout="${3:-900}"

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

  local pr_count
  pr_count=$(kubectl get provisioningrequest -n default --no-headers 2>/dev/null | grep -c "${job_name}" || true)
  echo -e "  ${DIM}ProvisioningRequests for this job: ${pr_count}${RESET}"

  if [[ "${pr_count}" -gt 0 ]]; then
    kubectl get provisioningrequest -n default --no-headers | grep "${job_name}" | \
      awk '{printf "    %s   %s\n", $1, $2}'
  fi

  spin_until "${label}: pod scheduled" \
    "kubectl get pods -n default -l job-name=${job_name} -o jsonpath='{.items[0].spec.nodeName}' | grep -q ." 600

  local node
  node=$(kubectl get pods -n default -l job-name="${job_name}" \
    -o jsonpath='{.items[0].spec.nodeName}')
  echo -e "  ${BOLD}${ARROW} Pod node: ${BG_YELLOW}${WHITE} ${node} ${RESET}"

  spin_until "${label}: job completed" \
    "kubectl get job ${job_name} -n default -o jsonpath='{.status.conditions[?(@.type==\"Complete\")].status}' | grep -q True" "${pr_timeout}"

  # Export observations
  declare -g "${label}_FLAVOR=${flavor}"
  declare -g "${label}_NODE=${node}"
  declare -g "${label}_PR_COUNT=${pr_count}"
}

# ---------------------------------------------------------------------------
clear
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║   Experiment: warm reuse via check-capacity flavor   ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

step "Clearing any prior test workloads..."
kubectl delete job job-reuse-1 job-reuse-2 --ignore-not-found=true &>/dev/null
sleep 3

# ---------------------------------------------------------------------------
header "Job 1 — cold-start (expect flavor-ondemand, new PR, ~30-120s)"
submit_job job-reuse-1
ok "Submitted job-reuse-1"
observe_job job-reuse-1 JOB1

# ---------------------------------------------------------------------------
header "Brief pause — node should remain warm (balanced profile, ~10 min)"
step "Waiting 15s before submitting job 2..."
sleep 15

# ---------------------------------------------------------------------------
header "Job 2 — within warm window (expect flavor-flex-warm, NO new PR)"
submit_job job-reuse-2
ok "Submitted job-reuse-2"
observe_job job-reuse-2 JOB2 300

# ---------------------------------------------------------------------------
header "Findings"

echo ""
echo -e "  ${BOLD}Job 1:${RESET}"
echo -e "    Flavor:           ${JOB1_FLAVOR}"
echo -e "    Node:             ${JOB1_NODE}"
echo -e "    PR count:         ${JOB1_PR_COUNT}"
echo ""
echo -e "  ${BOLD}Job 2:${RESET}"
echo -e "    Flavor:           ${JOB2_FLAVOR}"
echo -e "    Node:             ${JOB2_NODE}"
echo -e "    PR count:         ${JOB2_PR_COUNT}"
echo ""

VERDICT=""
if [[ "${JOB2_FLAVOR}" == "flavor-flex-warm" ]]; then
  VERDICT="REUSE WORKS — Kueue cascaded check-capacity → admitted onto warm node"
  COLOR="${BG_GREEN}"
elif [[ "${JOB2_FLAVOR}" == "flavor-ondemand" && "${JOB2_NODE}" == "${JOB1_NODE}" ]]; then
  VERDICT="PARTIAL — flex-warm was skipped, but queued-prov reused the warm node anyway"
  COLOR="${BG_YELLOW}"
elif [[ "${JOB2_FLAVOR}" == "flavor-ondemand" && "${JOB2_NODE}" != "${JOB1_NODE}" ]]; then
  VERDICT="REUSE FAILS — flex-warm did not admit, queued-prov provisioned new node"
  COLOR="${BG_RED}"
else
  VERDICT="INCONCLUSIVE — see flavor/node values above"
  COLOR="${BG_YELLOW}"
fi

echo -e "  ${BOLD}${COLOR}${WHITE}  ${VERDICT}  ${RESET}"
echo ""
echo -e "  ${DIM}All ProvisioningRequests in this run:${RESET}"
kubectl get provisioningrequest -n default --no-headers 2>/dev/null | \
  awk '{printf "    %-40s %s\n", $1, $2}' || echo "    (none)"
echo ""
