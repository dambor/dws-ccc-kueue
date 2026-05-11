#!/bin/bash
set -e

PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
CLUSTER_NAME=${CLUSTER_NAME:-"dws-ccc-kueue-cluster"}
REGION=${REGION:-"us-central1"}

echo "Project:      ${PROJECT_ID}"
echo "Cluster name: ${CLUSTER_NAME}"
echo "Region:       ${REGION}"
echo ""
read -r -p "This will permanently delete the cluster and all resources. Confirm? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo ""
echo "[1/2] Deleting GKE cluster ${CLUSTER_NAME}..."
gcloud container clusters delete "${CLUSTER_NAME}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --quiet

echo "[2/2] Done. Cluster and all resources deleted."
