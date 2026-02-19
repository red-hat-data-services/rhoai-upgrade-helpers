# Kubeflow Training Operator Verification Script

Helper script for validating Kubeflow Training Operator is still functioning as expected after migration from RHOAI 2.x
to RHOAI 3.x.

## Prerequisites

- `oc` CLI logged in with cluster-admin privileges
- Cluster admin access or the following permissions:

  | Resource   | Permission                 |
  |------------|----------------------------|
  | Namespace  | create, delete             |
  | PyTorchJob | clusterwide create, delete |
  | Pod        | clusterwide get, watch     |

Use the following commands to confirm you have the correct permissions.

```shell
oc auth can-i create namespaces -A
oc auth can-i delete namespaces -A
oc auth can-i create pytorchjobs -A
oc auth can-i delete pytorchjobs -A
oc auth can-i create pods -A
oc auth can-i watch pods -A
```

All above commands should output _**yes**_.

### Important Prerequisite Consideration

If you are performing an OCP upgrade, we recommend that administrators ensure that no PyTorchJobs are executing during
the upgrade, or the jobs include checkpointing so they are resilient to failure. OCP upgrades may require nodes to be
terminated which may cause PyTorchJobs to be interrupted.
You can list PyTorchJob resources in your cluster using `oc get pytorchjobs -A`.

# Examples

```bash
# Verify migration
./kubeflow-trainer-verification.sh
```
