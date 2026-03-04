# Workbench 2.x -> 3.x Upgrade Scripts

Helper script for migrating RHOAI workbenches from the OAuth-proxy auth model (RHOAI 2.x) to kube-rbac-proxy (RHOAI 3.x).

## Prerequisites

- `oc` CLI logged in with cluster-admin privileges
- `jq` installed

## Usage

```bash
./workbench-2.x-to-3.x-upgrade.sh <command> [options]
```

One of the following targeting modes is required:

- **Single workbench:** `--name <name> --namespace <namespace>`
- **All workbenches:** `--all`

The `patch` and `cleanup` commands show interactive confirmation prompts by default.
Use `-y` / `--yes` to skip prompts (for CI/automation).

## Commands

### Main workflow commands (run in order: `patch` -> `verify` -> `cleanup`)

| Command   | Description |
|-----------|-------------|
| `list`    | Identify legacy, migrated, and invalid workbenches by inspecting notebook annotations. |
| `patch`   | Patch notebook CR for the 3.x auth model (removes oauth-proxy sidecar, updates annotations, removes legacy settings, deletes StatefulSet). |
| `verify`  | Verify migration and/or cleanup state (`--phase migration\|cleanup\|all`). |
| `cleanup` | Remove leftover OAuth resources (Route, Service, Secrets, OAuthClient). |

### Troubleshooting command

| Command | Description |
|---------|-------------|
| `attach-kueue-label` | Add `kueue.x-k8s.io/queue-name` label to notebooks in Kueue-managed namespaces (used only when odh-cli pre-check fails for missing Kueue label). |

## Options

| Option | Description |
|--------|-------------|
| `--name NAME` | Notebook name (required for single-workbench mode). |
| `--namespace NAMESPACE` | Notebook namespace (required for single-workbench mode). |
| `--all` | Operate on every notebook in the cluster. |
| `--phase PHASE` | Verify phase for `verify`: `migration`, `cleanup`, or `all` (default: `migration`). |
| `--skip-stop` | For `patch` only: skip automatic stop/restart of running workbenches. |
| `--with-cleanup` | For `patch` only: run `cleanup` automatically after successful patching. |
| `--queue-name NAME` | For `attach-kueue-label`: queue-name value (default: `default`). |
| `-y`, `--yes` | Skip confirmation prompts. |

## Examples

```bash
# List migration state for all workbenches
./workbench-2.x-to-3.x-upgrade.sh list --all

# Patch one workbench, then run cleanup automatically
./workbench-2.x-to-3.x-upgrade.sh patch --name my-wb --namespace my-ns --with-cleanup

# Patch all workbenches and let the script stop/restart running ones automatically
./workbench-2.x-to-3.x-upgrade.sh patch --all

# Patch all workbenches without automatic stop/restart (manual lifecycle handling)
./workbench-2.x-to-3.x-upgrade.sh patch --all --skip-stop

# Verify only cleanup state across all workbenches
./workbench-2.x-to-3.x-upgrade.sh verify --all --phase cleanup

# Cleanup stale OAuth resources for all workbenches
./workbench-2.x-to-3.x-upgrade.sh cleanup --all

# Troubleshooting: attach Kueue queue-name label
./workbench-2.x-to-3.x-upgrade.sh attach-kueue-label --all --queue-name default
```

## Important notes for patching

- `patch` modifies notebook CRs and deletes StatefulSets, which restarts running workbenches.
- By default, the script automatically stops still-running workbenches before patching and restarts those it stopped afterwards.
- Use `--skip-stop` only if you are handling stop/start yourself and understand the risk of disruption/data loss.
- In Kueue-managed namespaces, you may still need to manually restart some workbenches that were running before migration.

## Recommended workflow

1. **Stop** all workbenches that will be migrated (via the RHOAI Dashboard or `oc`).
2. **List** current state: `./workbench-2.x-to-3.x-upgrade.sh list --all`
3. **Patch**: `./workbench-2.x-to-3.x-upgrade.sh patch --all`
4. **Verify** migration: `./workbench-2.x-to-3.x-upgrade.sh verify --all`
5. **Cleanup** (optional or use `--with-cleanup`): `./workbench-2.x-to-3.x-upgrade.sh cleanup --all`
6. **Start** the workbenches again.

> **Note:**
> In case of workbenches managed by Kueue, you may have to restart these manually to boot up properly if they were 
in running state before the migration.