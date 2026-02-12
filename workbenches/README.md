# Workbench 2.x → 3.x Upgrade Scripts

Helper script for migrating RHOAI workbenches from the OAuth-proxy auth model (RHOAI 2.x) to kube-rbac-proxy (RHOAI 3.x).

## Prerequisites

- `oc` CLI logged in with cluster-admin privileges
- `jq` installed

## Usage

```bash
./workbench-2.x-to-3.x-upgrade.sh <command> [--name NAME --namespace NAMESPACE | --all]
```

### Commands

| Command   | Description |
|-----------|-------------|
| `patch`   | Patch notebook CR — removes oauth-proxy sidecar, legacy annotations/finalizers/volumes, strips `--ServerApp.tornado_settings` from `NOTEBOOK_ARGS`, and deletes the StatefulSet. |
| `cleanup` | Remove leftover OAuth related resources (Route, Services, Secrets, OAuthClient). |
| `verify`  | Check that the migration was applied correctly. |

### Targeting

- **Single workbench:** `--name <name> --namespace <namespace>`
- **All workbenches:** `--all`

## Examples

```bash
# Patch a single workbench
./workbench-2.x-to-3.x-upgrade.sh patch --name my-wb --namespace my-ns

# Patch all workbenches in the cluster
./workbench-2.x-to-3.x-upgrade.sh patch --all

# Clean up stale OAuth related resources for all workbenches
./workbench-2.x-to-3.x-upgrade.sh cleanup --all

# Verify migration for a single workbench
./workbench-2.x-to-3.x-upgrade.sh verify --name my-wb --namespace my-ns
```

## Important: stop workbenches before patching

The patch operation modifies the notebook CR and deletes its StatefulSet, which causes
running workbenches to restart. To avoid potential data loss or disruption to users,
**stop all affected workbenches before running the patch** and start them again
afterwards.

## Recommended workflow

1. **Stop** all workbenches that will be migrated (via the RHOAI Dashboard or `oc`).
2. **Patch** — `./workbench-2.x-to-3.x-upgrade.sh patch --all`
3. **Verify** — `./workbench-2.x-to-3.x-upgrade.sh verify --all`
4. **Cleanup** (optional) — `./workbench-2.x-to-3.x-upgrade.sh cleanup --all`
5. **Start** the workbenches again.

> **Note:**
> In case of workbenches managed by Kueue, you may have to restart these manually to boot up properly if they were in running state before the migration.
