# DWS + CCC + Kueue on GKE

Integration of **Dynamic Workload Scheduler (DWS)**, **Custom Compute Class (CCC)**, and **Kueue** on Google Kubernetes Engine for cost-efficient, on-demand GPU provisioning for batch/ML workloads.

## Architecture

```
Job submitted
    │
    ▼
Kueue (queue management + quota control)
    │
    ├─ flavor-spot ──────► Spot GPU pool (cluster autoscaler)
    │   cheaper, best-effort     gpu-dws-spot-pool (T4, min 0 nodes)
    │
    └─ flavor-ondemand ──► On-demand GPU pool (DWS)
        guaranteed               gpu-dws-pool (T4, min 0 nodes)
        ProvisioningRequest      queued-provisioning.gke.io
```

**CCC** (`ccc-dws`) defines priority between pools — spot first, on-demand as fallback.  
**Kueue** manages the job queue and selects the flavor based on CCC priority.  
**DWS** provisions GPU nodes on-demand only when a job is admitted — zero idle cost.

## Components

| File | Purpose |
|---|---|
| `deploy.sh` | Full setup: cluster, GPU node pools, Kueue, CCC, all resources |
| `destroy.sh` | Tears down the entire cluster |
| `test.sh` | Visual end-to-end integration test |
| `ccc.yaml` | Custom Compute Class — spot-first, on-demand fallback |
| `kueue-config.yaml` | ResourceFlavors, ClusterQueue, LocalQueue, AdmissionChecks |
| `test-job.yaml` | Sample GPU job (T4, 1 GPU, 2 min runtime) |

## Prerequisites

- GCP project with billing enabled
- `gcloud` CLI authenticated
- GPU quota: `GPUS_ALL_REGIONS` ≥ 1 and `NVIDIA_T4_GPUS` ≥ 1 in `us-central1`

## Usage

```bash
# Deploy everything from scratch
PROJECT_ID=your-project ./deploy.sh

# Run the integration test
./test.sh

# Tear down
./destroy.sh
```

### Optional overrides

| Variable | Default | Example |
|---|---|---|
| `PROJECT_ID` | `gcloud config get-value project` | `my-project` |
| `CLUSTER_NAME` | `dws-ccc-kueue-cluster` | `my-cluster` |
| `REGION` | `us-central1` | `us-east1` |
| `GPU_TYPE` | `nvidia-tesla-t4` | `nvidia-tesla-a100` |
| `MACHINE_TYPE` | `n1-standard-4` | `a2-highgpu-1g` |
| `KUEUE_VERSION` | `v0.10.0` | `v0.11.0` |

## Kueue Configuration

Two flavors with different provisioning strategies:

| Flavor | Pool | Provisioner | Admission Check |
|---|---|---|---|
| `flavor-spot` | `gpu-dws-spot-pool` | Cluster Autoscaler | None (immediate) |
| `flavor-ondemand` | `gpu-dws-pool` | DWS (`queued-provisioning.gke.io`) | `dws-check` |

Kueue tries `flavor-spot` first. When spot quota is exhausted, it falls back to `flavor-ondemand` with DWS queuing.

## Test Results

End-to-end test on GKE `1.35.3-gke.1737000`, `us-central1`, T4 GPU:

```
  ✔ Kueue controller running          (1s)
  ✔ ComputeClass CRD present          (0s)
  ✔ ClusterQueue CRD present          (0s)
  ✔ Job submitted to local-queue-dws
  ✔ Workload admitted                 (0s)   → CCC selected: flavor-spot
  ✔ Spot flavor → cluster autoscaler
  ✔ Pods running on GPU node          (106s) → gke-..-gpu-dws-spot-pool-..
  ✔ 1 new GPU node provisioned via CCC [flavor-spot]
  ✔ Job completed                     (121s)

  Total time: 234s
```

## Known Limitations

- **Spot + DWS**: GKE does not support `--enable-queued-provisioning` with `--spot` on the same node pool. Spot is managed by the regular cluster autoscaler; DWS queuing applies only to the on-demand pool.
- **Kueue fallback**: The switch from `flavor-spot` to `flavor-ondemand` is triggered by Kueue quota exhaustion, not by spot hardware unavailability. If spot hardware is scarce, pods will remain pending until capacity appears.
- **CCC + DWS**: CCC manages pool priority; DWS provisions within the selected pool. Full integration (CCC driving DWS machine selection) is not yet natively supported by GKE.
