# AI Pipelines Upgrade Helpers

Scripts to assist with upgrading RHOAI AI Pipelines (DataSciencePipelinesApplication / DSPA).

## Scripts

### `check_before_upgrade.sh`

Run **before** upgrading. Does three things:

1. Migrates any DSPAs still using the deprecated `v1alpha1` API to `v1`.
2. Warns about custom roles that may need updating (see `update_dsp_role.sh`).
3. Captures current pod health state to `/tmp/dspa_pre_upgrade_pods.json` for post-upgrade comparison.

```bash
# Optional env vars:
# DSPA_STATE_FILE=/tmp/dspa_pre_upgrade_pods.json

./check_before_upgrade.sh
```

### `post_upgrade_check.sh`

Run **after** upgrading. Compares current pod health against the pre-upgrade snapshot. Waits up to `WAIT_TIMEOUT` seconds for pods to recover before reporting failure.

```bash
# Optional env vars:
# DSPA_STATE_FILE=/tmp/dspa_pre_upgrade_pods.json  (must match pre-upgrade run)
# DSPA_WAIT_TIMEOUT=120

./post_upgrade_check.sh
```

### `update_dsp_role.sh`

Patches a custom RBAC Role to add the `datasciencepipelinesapplications/api` subresource. Use this when `check_before_upgrade.sh` reports custom roles that need updating.

After patching, the script validates the update by fetching the live role and confirming the expected rule is present (correct API group, resource, resource name, and verbs). It exits non-zero if the patch or validation fails.

```bash
./update_dsp_role.sh ROLE_NAME NAMESPACE DSPA_NAME VERBS

# Example:
./update_dsp_role.sh my-role my-namespace my-dspa get,list,create
```

## Prerequisites

- `kubectl` configured against the target cluster
- `jq` installed
