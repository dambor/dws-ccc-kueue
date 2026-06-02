#!/bin/bash
set -e

PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
CLUSTER_NAME=${CLUSTER_NAME:-"dws-ccc-kueue-cluster"}
REGION=${REGION:-"us-central1"}
KUEUE_VERSION=${KUEUE_VERSION:-"v0.18.0"}
GPU_TYPE=${GPU_TYPE:-"nvidia-tesla-t4"}
MACHINE_TYPE=${MACHINE_TYPE:-"n1-standard-4"}
GPU_ZONES=${GPU_ZONES:-"us-central1-a,us-central1-b,us-central1-c,us-central1-f"}

echo "Project:       ${PROJECT_ID}"
echo "Cluster name:  ${CLUSTER_NAME}"
echo "Region:        ${REGION}"
echo "Kueue version: ${KUEUE_VERSION}"
echo "GPU type:      ${GPU_TYPE} on ${MACHINE_TYPE}"
echo ""

# ---------------------------------------------------------------------------
# 1. APIs
# ---------------------------------------------------------------------------
echo "[1/6] Enabling required GCP APIs..."
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  --project="${PROJECT_ID}"

# ---------------------------------------------------------------------------
# 2. Auth plugin
# ---------------------------------------------------------------------------
if ! command -v gke-gcloud-auth-plugin &>/dev/null; then
  echo "Installing gke-gcloud-auth-plugin..."
  gcloud components install gke-gcloud-auth-plugin --quiet
fi
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

# ---------------------------------------------------------------------------
# 3. GKE cluster (Standard, rapid channel — required for DWS + CCC)
# ---------------------------------------------------------------------------
echo "[2/6] Creating GKE Standard cluster..."
gcloud container clusters create "${CLUSTER_NAME}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --release-channel=rapid \
  --num-nodes=1 \
  --machine-type=e2-standard-4 \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --autoscaling-profile=balanced \
  --no-enable-basic-auth \
  --enable-private-nodes \
  --enable-ip-alias \
  --master-ipv4-cidr=172.16.0.0/28 \
  --enable-private-endpoint

echo "Fetching cluster credentials..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

# ---------------------------------------------------------------------------
# 4. GPU node pools with DWS queued provisioning
#    CCC selects between them by priority: spot first, on-demand as fallback
#    DWS provisions nodes within whichever pool CCC selects
# ---------------------------------------------------------------------------
echo "[3/6] Creating GPU node pools (spot + on-demand)..."

# Spot pool — CCC prioridade 1; cluster autoscaler gerencia; sem queued-provisioning (incompatível com spot)
gcloud container node-pools create gpu-dws-spot-pool \
  --cluster="${CLUSTER_NAME}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --machine-type="${MACHINE_TYPE}" \
  --accelerator="type=${GPU_TYPE},count=1,gpu-driver-version=latest" \
  --spot \
  --num-nodes=0 \
  --enable-autoscaling \
  --total-max-nodes=1 \
  --node-locations="${GPU_ZONES}" \
  --node-labels=cloud.google.com/compute-class=ccc-dws,pool-type=spot

# Flex-start (NON-queued) pool — CCC prioridade 2; DWS Flex pricing + node recycling
# across workloads (supports reuse). No ProvisioningRequest, no gang-scheduling.
gcloud container node-pools create gpu-dws-flex-pool \
  --cluster="${CLUSTER_NAME}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --machine-type="${MACHINE_TYPE}" \
  --accelerator="type=${GPU_TYPE},count=1,gpu-driver-version=latest" \
  --flex-start \
  --num-nodes=0 \
  --enable-autoscaling \
  --total-min-nodes=0 \
  --total-max-nodes=2 \
  --location-policy=ANY \
  --reservation-affinity=none \
  --node-locations="${GPU_ZONES}" \
  --node-labels=cloud.google.com/compute-class=ccc-dws,pool-type=flex

# On-demand pool — CCC prioridade 3; DWS Flex + queued provisioning para gang-scheduling
# (multi-node atomic). NÃO reusa nós entre workloads (PR per-workload).
gcloud container node-pools create gpu-dws-pool \
  --cluster="${CLUSTER_NAME}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --machine-type="${MACHINE_TYPE}" \
  --accelerator="type=${GPU_TYPE},count=1,gpu-driver-version=latest" \
  --enable-queued-provisioning \
  --num-nodes=0 \
  --enable-autoscaling \
  --total-max-nodes=1 \
  --reservation-affinity=none \
  --node-locations="${GPU_ZONES}" \
  --node-labels=cloud.google.com/compute-class=ccc-dws,pool-type=ondemand

# ---------------------------------------------------------------------------
# 5. Kueue
# ---------------------------------------------------------------------------
echo "[4/6] Installing Kueue ${KUEUE_VERSION}..."

kubectl apply --server-side --validate=false -f \
  "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml" 

echo "Waiting for Kueue controller to be ready (up to 5 min)..."
kubectl wait --for=condition=Available \
  deployment/kueue-controller-manager \
  -n kueue-system \
  --timeout=300s

echo "Giving the API server 5 seconds to register CRDs..."
sleep 5

# ---------------------------------------------------------------------------
# 6. Verify CRDs
# ---------------------------------------------------------------------------
echo "[5/6] Verifying required CRDs..."
for crd in \
  "computeclasses.cloud.google.com" \
  "clusterqueues.kueue.x-k8s.io" \
  "workloads.kueue.x-k8s.io"; do
  if kubectl get crd "${crd}" &>/dev/null; then
    echo "  OK: ${crd}"
  else
    echo "  MISSING: ${crd}"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 7. Application resources
# ---------------------------------------------------------------------------
echo "[6/6] Deploying CCC + Kueue + DWS resources..."
kubectl apply -f ccc.yaml
kubectl apply -f kueue-config.yaml

echo ""
echo "Deployment complete!"
kubectl get computeclass ccc-dws
kubectl get clusterqueue cluster-queue-dws
kubectl get localqueue local-queue-dws
echo ""
echo "Run ./test.sh to execute the end-to-end integration test."
