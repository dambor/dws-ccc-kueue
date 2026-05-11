#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# Colors & symbols
# ---------------------------------------------------------------------------
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RED="\033[31m"
WHITE="\033[97m"
BG_BLUE="\033[44m"
BG_GREEN="\033[42m"
BG_RED="\033[41m"

CHECK="${GREEN}✔${RESET}"
CROSS="${RED}✖${RESET}"
ARROW="${CYAN}➜${RESET}"
CLOCK="${YELLOW}⏱${RESET}"

SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
header() {
  echo ""
  echo -e "${BOLD}${BG_BLUE}${WHITE}  $1  ${RESET}"
  echo -e "${DIM}────────────────────────────────────────────────────────${RESET}"
}

step() {
  echo -e "  ${ARROW} $1"
}

ok() {
  echo -e "  ${CHECK} ${GREEN}$1${RESET}"
}

fail() {
  echo -e "  ${CROSS} ${RED}$1${RESET}"
  exit 1
}

elapsed() {
  local start=$1
  echo $(( $(date +%s) - start ))s
}

spin_until() {
  local label="$1"
  local cmd="$2"
  local timeout="${3:-300}"
  local i=0
  local start
  start=$(date +%s)

  while ! eval "${cmd}" &>/dev/null; do
    local frame="${SPINNER_FRAMES[$((i % ${#SPINNER_FRAMES[@]}))]}"
    printf "\r  ${YELLOW}${frame}${RESET}  %s  ${DIM}(%ss)${RESET}" "${label}" "$(elapsed "${start}")"
    sleep 0.2
    i=$(( i + 1 ))
    if (( $(date +%s) - start > timeout )); then
      printf "\r"
      fail "Timeout after ${timeout}s waiting for: ${label}"
    fi
  done
  printf "\r"
  ok "${label}  ${DIM}($(elapsed "${start}"))${RESET}"
}

watch_field() {
  local label="$1"
  local get_cmd="$2"
  local expected="$3"
  local timeout="${4:-300}"
  local i=0
  local start
  start=$(date +%s)

  while true; do
    local value
    value=$(eval "${get_cmd}" 2>/dev/null || echo "")
    if [[ "${value}" == *"${expected}"* ]]; then
      printf "\r"
      ok "${label}  ${DIM}[${value}] ($(elapsed "${start}"))${RESET}"
      return
    fi
    local frame="${SPINNER_FRAMES[$((i % ${#SPINNER_FRAMES[@]}))]}"
    printf "\r  ${YELLOW}${frame}${RESET}  %s  ${DIM}[%s] (%ss)${RESET}" "${label}" "${value}" "$(elapsed "${start}")"
    sleep 1
    i=$(( i + 1 ))
    if (( $(date +%s) - start > timeout )); then
      printf "\r"
      fail "Timeout after ${timeout}s — last value: ${value}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
cleanup() {
  if [[ "${CLEANUP:-true}" == "true" ]]; then
    echo ""
    step "Removing test job..."
    kubectl delete job job-dws-test --ignore-not-found=true &>/dev/null
    ok "Test job removed"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
clear
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║          DWS + CCC + Kueue — Integration Test        ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

TOTAL_START=$(date +%s)

# ---------------------------------------------------------------------------
# Step 1 — Cluster & Kueue health
# ---------------------------------------------------------------------------
header "1 / 5  •  Cluster & Kueue health"

spin_until "Kueue controller running" \
  "kubectl get deployment kueue-controller-manager -n kueue-system -o jsonpath='{.status.readyReplicas}' | grep -q '[1-9]'"

spin_until "ComputeClass CRD present" \
  "kubectl get crd computeclasses.cloud.google.com"

spin_until "ClusterQueue CRD present" \
  "kubectl get crd clusterqueues.kueue.x-k8s.io"

# ---------------------------------------------------------------------------
# Step 2 — Submit job
# ---------------------------------------------------------------------------
header "2 / 5  •  Submitting test job"

step "Removing any previous test job..."
kubectl delete job job-dws-test --ignore-not-found=true &>/dev/null
sleep 2

step "Applying test-job.yaml..."
kubectl apply -f test-job.yaml &>/dev/null
ok "Job job-dws-test submitted to local-queue-dws"

# ---------------------------------------------------------------------------
# Step 3 — Kueue admission + detect flavor (spot vs on-demand/DWS)
# ---------------------------------------------------------------------------
header "3 / 5  •  Kueue admission  (CCC flavor selection)"

spin_until "Workload created by Kueue" \
  "kubectl get workload -n default | grep -q 'job-dws-test'"

WORKLOAD_NAME=$(kubectl get workload -n default -o name | grep job-dws-test | head -1 | cut -d/ -f2)
echo -e "  ${DIM}Workload: ${WORKLOAD_NAME}${RESET}"

watch_field "Workload admitted" \
  "kubectl get workload ${WORKLOAD_NAME} -n default -o jsonpath='{.status.conditions[?(@.type==\"Admitted\")].status}'" \
  "True" 60

FLAVOR=$(kubectl get workload "${WORKLOAD_NAME}" -n default \
  -o jsonpath='{.status.admission.podSetAssignments[0].flavors.cpu}' 2>/dev/null || echo "unknown")
echo -e "  ${ARROW} CCC selected flavor: ${BOLD}${FLAVOR}${RESET}"

# ---------------------------------------------------------------------------
# Step 4 — Node provisioning (path depends on flavor)
# ---------------------------------------------------------------------------
header "4 / 5  •  Node provisioning  (DWS + CCC)"

NODES_BEFORE=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
echo -e "  ${DIM}Nodes before: ${NODES_BEFORE}${RESET}"

if [[ "${FLAVOR}" == "flavor-ondemand" ]]; then
  # DWS path: wait for ProvisioningRequest to be accepted and provisioned
  spin_until "ProvisioningRequest created by Kueue" \
    "kubectl get provisioningrequest -n default | grep -q 'job-dws-test'" 60

  PR_NAME=$(kubectl get provisioningrequest -n default -o name | grep job-dws-test | head -1 | cut -d/ -f2)
  echo -e "  ${DIM}ProvisioningRequest: ${PR_NAME}${RESET}"

  watch_field "DWS accepted request" \
    "kubectl get provisioningrequest ${PR_NAME} -n default -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}'" \
    "True" 120

  watch_field "DWS provisioned GPU node" \
    "kubectl get provisioningrequest ${PR_NAME} -n default -o jsonpath='{.status.conditions[?(@.type==\"Provisioned\")].status}'" \
    "True" 900
else
  # Spot path: cluster autoscaler provisions the node
  ok "Spot flavor selected — cluster autoscaler will provision node"
fi

spin_until "Pods created" \
  "kubectl get pods -n default | grep -q 'job-dws-test'" 60

watch_field "Pods running on GPU node" \
  "kubectl get pods -n default -l job-name=job-dws-test -o jsonpath='{.items[0].status.phase}'" \
  "Running" 600

NODES_AFTER=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
NEW_NODES=$(( NODES_AFTER - NODES_BEFORE ))
if (( NEW_NODES > 0 )); then
  ok "${NEW_NODES} new GPU node(s) provisioned via CCC [${FLAVOR}]"
else
  ok "Pods scheduled on existing nodes"
fi

kubectl get pods -n default -l job-name=job-dws-test -o wide --no-headers | \
  awk '{printf "  '"${DIM}"'Pod: %-40s Node: %s'"${RESET}"'\n", $1, $7}'

# ---------------------------------------------------------------------------
# Step 5 — Job completion
# ---------------------------------------------------------------------------
header "5 / 5  •  Job completion"

watch_field "Job completed" \
  "kubectl get job job-dws-test -n default -o jsonpath='{.status.conditions[?(@.type==\"Complete\")].status}'" \
  "True" 600

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL=$(elapsed "${TOTAL_START}")
echo ""
echo -e "${BOLD}${BG_GREEN}${WHITE}  RESULT  ${RESET}"
echo ""
echo -e "  ${CHECK} ${BOLD}All stages passed${RESET}"
echo -e "  ${CLOCK} Total time: ${BOLD}${TOTAL}${RESET}"
echo ""
echo -e "  ${DIM}Resources:${RESET}"
kubectl get computeclass ccc-dws            2>/dev/null | tail -1 | awk '{printf "    ComputeClass:   %s\n", $1}'
kubectl get clusterqueue cluster-queue-dws  2>/dev/null | tail -1 | awk '{printf "    ClusterQueue:   %s\n", $1}'
kubectl get localqueue local-queue-dws      2>/dev/null | tail -1 | awk '{printf "    LocalQueue:     %s\n", $1}'
kubectl get job job-dws-test                2>/dev/null | tail -1 | awk '{printf "    Job:            %s  completions: %s\n", $1, $2}'
echo ""
