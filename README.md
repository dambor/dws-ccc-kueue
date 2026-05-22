# DWS + CCC + Kueue on GKE

Three-tier GPU provisioning for batch/ML workloads, using Custom Compute Class
to route pods by cost preference, Kueue for queue and quota, and DWS Flex Start
in two different modes for capacity acquisition.

## Tiers

```
Job submitted
    │
    ▼
Kueue (queue + quota)
    │
    ├─ flavor-spot ──────► gpu-dws-spot-pool (--spot)
    │   no admission check
    │
    ├─ flavor-flex ──────► gpu-dws-flex-pool (--flex-start)
    │   no admission check       supports node reuse across workloads
    │
    └─ flavor-ondemand ──► gpu-dws-pool (--flex-start --enable-queued-provisioning)
        dws-check (PR)           gang-scheduling, no reuse
```

CCC routes new pods to the highest-priority pool with capacity. Kueue's
ClusterQueue mirrors that order across the three ResourceFlavors. Falling
through to the next tier happens when the current flavor's quota is exhausted.

## The two Flex Start modes

Both DWS Flex Start modes are supported by GKE and behave differently:

- `--flex-start` alone (FSNQ): autoscaler provisions and recycles nodes the
  normal way. Flex Start pricing, up to 7 days per VM. Pods land via
  `nodeSelector: cloud.google.com/gke-flex-start=true`.
- `--flex-start --enable-queued-provisioning`: every workload creates a
  ProvisioningRequest with `queued-provisioning.gke.io`. Each PR gets a
  dedicated capacity lease and the nodes it provisions are not reused for the
  next workload. Right for multi-node gang-scheduled training; wrong for
  sequential batch.

From the GKE docs: *"Flex-start supports node recycling, while Flex-start with
queued provisioning does not."* This repo has both pools side by side so the
difference is observable.

## Files

| File | Purpose |
|---|---|
| `deploy.sh` | Cluster + 3 GPU pools + Kueue + applies the YAML. ~10 min. |
| `destroy.sh` | Tears down the cluster. |
| `ccc.yaml` | The three-tier CCC. |
| `kueue-config.yaml` | ResourceFlavors, ClusterQueue, AdmissionChecks. Also includes a separate experimental queue (`cluster-queue-flex-pr`) for PR-gated FSNQ. |
| `test-job.yaml` | Single 1-GPU job used by `test.sh`. |
| `test.sh` | Single-job demo — shows which tier CCC selected. |
| `test-reuse.sh` | Two-job demo — verifies warm-node reuse on the FSNQ pool. |
| `test-flex-pr.sh` | Experiment — Kueue + ProvisioningRequest + reuse on FSNQ, using `best-effort-atomic-scale-up.autoscaling.x-k8s.io`. |

## Prerequisites

- GCP project with billing
- `gcloud` authenticated
- GPU quota: `GPUS_ALL_REGIONS` ≥ 2 and `NVIDIA_T4_GPUS` ≥ 2 in the chosen region

## Usage

```bash
PROJECT_ID=your-project ./deploy.sh    # ~10 min
./test.sh                              # CCC routing demo
./test-reuse.sh                        # warm-reuse demo on FSNQ
./destroy.sh                           # cleanup
```

Overrides via env vars: `PROJECT_ID`, `CLUSTER_NAME`, `REGION`, `GPU_TYPE`,
`MACHINE_TYPE`, `KUEUE_VERSION`. Defaults are `us-central1` / `nvidia-tesla-t4`
/ `n1-standard-4` / Kueue `v0.10.0`.

## Warm reuse, with and without PR

`test-reuse.sh` covers the simple case: Kueue admits to `flavor-flex`, no
admission check, pods land on the FSNQ pool. Job 2 reuses Job 1's node because
the cluster autoscaler keeps idle nodes for ~10 minutes (`balanced` profile)
and nothing else is holding the capacity.

`test-flex-pr.sh` covers the harder case: Kueue + ProvisioningRequest on the
same FSNQ pool, via `best-effort-atomic-scale-up.autoscaling.x-k8s.io`. The
catch: the autoscaler holds a 10-minute capacity reservation tied to each PR.
While Job 1's PR exists, its reservation blocks Job 2's PR from claiming the
warm node. The fix is to delete the Job after it completes — the cascade
`Job → Workload → PR` releases the reservation. The script does this via
`ttlSecondsAfterFinished: 0` on the Job spec, which is the pattern customers
need in production batch pipelines if they want both Kueue + PR + reuse.

## Known limitations

- `--enable-queued-provisioning` and `--spot` cannot be combined on the same
  pool. Spot stays on its own pool with the regular autoscaler.
- Kueue's flavor cascade is quota-driven, not admission-check-driven. A flavor
  with available quota but a failing admission check (e.g.,
  `check-capacity.autoscaling.x-k8s.io` returning `CapacityIsNotFound`) stalls
  the workload rather than moving to the next flavor.
- CCC routes pods between pools; DWS provisions within whichever pool CCC
  picks. There is no integration where CCC drives DWS machine selection
  across heterogeneous GPU types in a single pool.
- The 10-minute capacity reservation from `best-effort-atomic-scale-up` is
  per-PR. Workloads with overlapping submission windows will not share a node
  unless the previous Job is cleaned up first (TTL or explicit delete).
