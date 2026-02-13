#!/bin/bash
#
# Workbench 2.x → 3.x Upgrade Helper
#
# Consolidates patch, cleanup, and verify operations for migrating
# RHOAI workbenches from OAuth-proxy (2.x) to kube-rbac-proxy (3.x).
#
# Usage:
#   ./workbench-2.x-to-3.x-upgrade.sh <command> [--name NAME --namespace NAMESPACE | --all]
#
# IMPORTANT: The patch operation causes running workbenches to restart.
# Stop all affected workbenches before patching to avoid data loss or
# disruption to users, and start them again afterwards.
#
# Commands:
#   patch    - Patch notebook resources for 3.x auth model
#   cleanup  - Remove stale OAuth routes, secrets, and OAuthClients
#   verify   - Verify the migration succeeded
#
# Examples:
#   ./workbench-2.x-to-3.x-upgrade.sh patch   --name my-wb --namespace my-ns
#   ./workbench-2.x-to-3.x-upgrade.sh patch   --all
#   ./workbench-2.x-to-3.x-upgrade.sh cleanup --all
#   ./workbench-2.x-to-3.x-upgrade.sh verify  --name my-wb --namespace my-ns
#

set -euo pipefail

# ──────────────────────────────────────────────
# Usage / help
# ──────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  patch    Patch notebook CR for the 3.x auth model (removes oauth-proxy
           sidecar, adds inject-auth annotation, deletes StatefulSet).
           WARNING: This causes running workbenches to restart. Stop them first.
  cleanup  Remove leftover OAuth resources (Route, Services, Secrets,
           OAuthClient) that are no longer needed after migration.
  verify   Check that the migration was applied correctly.

Options:
  --name NAME              Notebook name   (required for single-workbench mode)
  --namespace NAMESPACE    Notebook namespace (required for single-workbench mode)
  --all                    Operate on every notebook in the cluster
  -y, --yes                Skip confirmation prompts (for automation / CI)

One of "--name NAME --namespace NAMESPACE" or "--all" must be provided.

Examples:
  $(basename "$0") patch   --name my-wb --namespace my-ns
  $(basename "$0") cleanup --all
  $(basename "$0") verify  --name my-wb --namespace my-ns
EOF
    exit 1
}

# ──────────────────────────────────────────────
# Confirmation prompts
# ──────────────────────────────────────────────

# Print the cluster the user is currently connected to.
print_cluster_info() {
    local cluster server user
    cluster=$(oc whoami --show-server 2>/dev/null || echo "<unknown>")
    user=$(oc whoami 2>/dev/null || echo "<unknown>")
    echo "  Cluster: $cluster"
    echo "  User:    $user"
}

# Ask the user to type "yes" to continue. Aborts on anything else.
# Skipped when SKIP_CONFIRM=true (--yes flag).
ask_confirmation() {
    if [ "${SKIP_CONFIRM:-false}" = true ]; then
        return 0
    fi
    echo ""
    read -r -p "Type 'yes' to continue: " answer
    if [ "$answer" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
}

# Confirmation gate for the patch command.
confirm_patch() {
    cat <<'EOF'

╔════════════════════════════════════════════════════════════════╗
║                        *** WARNING ***                         ║
║                                                                ║
║  You are about to PATCH notebook resources on this cluster.    ║
║                                                                ║
║  This operation will:                                          ║
║   - Modify notebook CRs (annotations, containers, volumes)     ║
║   - Delete StatefulSets, causing RUNNING workbenches to        ║
║     RESTART                                                    ║
║   - Strip legacy OAuth-proxy configuration                     ║
║                                                                ║
║  BEFORE PROCEEDING, make sure you have:                        ║
║   1. Stopped all affected workbenches                          ║
║   2. Verified you are connected to the correct cluster         ║
║   3. Backed up any critical notebook CRs if needed             ║
║                                                                ║
║  RISK: Running this on active workbenches may cause DATA LOSS  ║
║  or DISRUPTION to users.                                       ║
╚════════════════════════════════════════════════════════════════╝
EOF
    print_cluster_info
    if [ "$ALL" = true ]; then
        echo "  Target:  ALL notebooks in the cluster"
    else
        echo "  Target:  notebook '$NAME' in namespace '$NAMESPACE'"
    fi
    ask_confirmation
}

# Confirmation gate for the cleanup command.
confirm_cleanup() {
    cat <<'EOF'

╔════════════════════════════════════════════════════════════════╗
║                        *** CAUTION ***                         ║
║                                                                ║
║  You are about to DELETE legacy OAuth resources on this        ║
║  cluster (Routes, Services, Secrets, OAuthClients).            ║
║                                                                ║
║  Only run this AFTER the patch + verify steps have completed   ║
║  successfully. Cleaning up before migration is finished may    ║
║  leave workbenches in a broken state.                          ║
╚════════════════════════════════════════════════════════════════╝
EOF
    print_cluster_info
    if [ "$ALL" = true ]; then
        echo "  Target:  ALL notebooks in the cluster"
    else
        echo "  Target:  notebook '$NAME' in namespace '$NAMESPACE'"
    fi
    ask_confirmation
}

# ──────────────────────────────────────────────
# Core functions (single workbench)
# ──────────────────────────────────────────────

# Patch a single notebook for the 3.x auth model.
#   $1 = notebook name
#   $2 = namespace
patch_workbench() {
    local name="$1"
    local namespace="$2"

    echo "Patching notebook '$name' in namespace '$namespace'..."

    # Generate the JSON Patch dynamically from the current notebook state
    PATCH=$(oc get notebook "$name" -n "$namespace" -o json | jq -c '
    [
      {"op":"add","path":"/metadata/annotations/notebooks.opendatahub.io~1inject-auth","value":"true"},
      {"op":"remove","path":"/metadata/annotations/notebooks.opendatahub.io~1inject-oauth"},
      {"op":"remove","path":"/metadata/annotations/notebooks.opendatahub.io~1oauth-logout-url"},
      (
        .spec.template.spec.containers | to_entries[] |
        select(.value.name == "oauth-proxy") |
        {"op":"remove", "path": "/spec/template/spec/containers/\(.key)"}
      ),
      (
        .metadata.finalizers // [] | to_entries[] |
        select(.value == "notebook-oauth-client-finalizer.opendatahub.io") |
        {"op":"remove", "path": "/metadata/finalizers/\(.key)"}
      ),
      (
        .spec.template.spec.volumes // [] | to_entries[] |
        select(.value.name | IN("oauth-config", "oauth-client", "tls-certificates")) |
        {"op":"remove", "path": "/spec/template/spec/volumes/\(.key)"}
      ),
      (
        # Strip --ServerApp.tornado_settings=... from the NOTEBOOK_ARGS env var.
        # This setting carried OAuth-proxy user/hub metadata that is no longer
        # needed with kube-rbac-proxy in 3.x.
        .spec.template.spec.containers | to_entries[] |
        .key as $ci |
        .value.env // [] | to_entries[] |
        select(.value.name == "NOTEBOOK_ARGS") |
        select(.value.value | test("--ServerApp\\.tornado_settings=")) |
        .key as $ei |
        (.value.value | gsub("[\\n\\r\\t ]*--ServerApp\\.tornado_settings=[^\\n]*"; "")) as $new_val |
        {"op":"replace", "path": "/spec/template/spec/containers/\($ci)/env/\($ei)/value", "value": $new_val}
      )
    ] | sort_by(.path) | reverse')

    # Execute the patch only if there is something to patch
    if [ "$PATCH" = "[]" ] || [ -z "$PATCH" ]; then
        echo "  Nothing to patch for '$name' — skipping."
        return 0
    fi

    # Apply the patch and delete the StatefulSet to work around the kueue
    # webhook sync issue: https://issues.redhat.com/browse/RHOAIENG-49007
    # WARNING: This causes running workbenches to restart. All affected
    #          workbenches should be stopped before running this operation
    #          to avoid data loss or user disruption.
    oc patch notebook "$name" -n "$namespace" --type='json' -p="$PATCH" \
        && oc delete statefulset -n "$namespace" "$name"

    echo "  Patch applied for '$name'."
}

# Remove stale OAuth-related resources for a single notebook.
#   $1 = notebook name
#   $2 = namespace
cleanup_workbench() {
    local name="$1"
    local namespace="$2"

    echo "=========================================================="
    echo " Starting cleanup for Notebook: $name"
    echo " Target Namespace:              $namespace"
    echo "=========================================================="

    echo "[1/3] Removing Route and Services..."
    oc delete route "$name" -n "$namespace" --ignore-not-found
    oc delete service "$name" "${name}-tls" -n "$namespace" --ignore-not-found

    echo "[2/3] Removing Secrets..."
    oc delete secret "${name}-oauth-client" "${name}-oauth-config" "${name}-tls" -n "$namespace" --ignore-not-found

    echo "[3/3] Removing OAuthClient: ${name}-${namespace}-oauth-client"
    oc delete oauthclient "${name}-${namespace}-oauth-client" --ignore-not-found

    echo "=========================================================="
    echo " Cleanup complete for '$name' in '$namespace'."
    echo "=========================================================="
}

# Verify migration status for a single notebook.
#   $1 = notebook name
#   $2 = namespace
verify_workbench() {
    local name="$1"
    local namespace="$2"
    local pass=true

    echo "=== Verifying Notebook: $name in $namespace ==="

    # Check inject-auth annotation (should be "true")
    AUTH=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.metadata.annotations.notebooks\.opendatahub\.io/inject-auth}' 2>/dev/null)
    if [ "$AUTH" = "true" ]; then
        echo "  PASS: inject-auth annotation is set to 'true'"
    else
        echo "  FAIL: inject-auth annotation missing or incorrect (found: '$AUTH')"
        pass=false
    fi

    # Check inject-oauth annotation (should NOT exist)
    OAUTH=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.metadata.annotations.notebooks\.opendatahub\.io/inject-oauth}' 2>/dev/null)
    if [ -z "$OAUTH" ]; then
        echo "  PASS: Legacy inject-oauth annotation removed"
    else
        echo "  FAIL: Legacy inject-oauth annotation still exists: '$OAUTH'"
        pass=false
    fi

    # Check that --ServerApp.tornado_settings is removed from NOTEBOOK_ARGS
    NB_ARGS=$(oc get notebook "$name" -n "$namespace" -o json 2>/dev/null \
        | jq -r '.spec.template.spec.containers[].env // [] | .[] | select(.name == "NOTEBOOK_ARGS") | .value' 2>/dev/null)
    if echo "$NB_ARGS" | grep -q -- "--ServerApp.tornado_settings="; then
        echo "  FAIL: --ServerApp.tornado_settings still present in NOTEBOOK_ARGS"
        pass=false
    else
        echo "  PASS: --ServerApp.tornado_settings removed from NOTEBOOK_ARGS"
    fi

    # Check sidecar containers
    CONTAINERS=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null)

    if echo "$CONTAINERS" | grep -q "kube-rbac-proxy"; then
        echo "  PASS: kube-rbac-proxy sidecar container present (RHOAI 3.x)"
    else
        echo "  FAIL: kube-rbac-proxy sidecar container missing"
        pass=false
    fi

    if echo "$CONTAINERS" | grep -q "oauth-proxy"; then
        echo "  FAIL: Legacy oauth-proxy sidecar still present (RHOAI 2.x)"
        pass=false
    else
        echo "  PASS: Legacy oauth-proxy sidecar removed"
    fi

    echo "  Containers found: $CONTAINERS"

    if [ "$pass" = true ]; then
        echo "=== RESULT: ALL CHECKS PASSED ==="
    else
        echo "=== RESULT: SOME CHECKS FAILED ==="
    fi
    echo ""
}

# ──────────────────────────────────────────────
# Batch helper — run a function for every notebook
# ──────────────────────────────────────────────
process_all() {
    local func="$1"

    oc get notebooks --all-namespaces \
        -o custom-columns=NAME:.metadata.name,NS:.metadata.namespace \
        --no-headers | while read -r nb_name nb_namespace; do
        "$func" "$nb_name" "$nb_namespace"
    done
}

# ──────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────
if [ $# -lt 2 ]; then
    usage
fi

COMMAND="$1"; shift

ALL=false
SKIP_CONFIRM=false
NAME=""
NAMESPACE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --all)
            ALL=true
            shift
            ;;
        --name)
            NAME="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option '$1'"
            usage
            ;;
    esac
done

# Validate targeting options
if [ "$ALL" = true ] && { [ -n "$NAME" ] || [ -n "$NAMESPACE" ]; }; then
    echo "Error: --all cannot be combined with --name/--namespace."
    usage
fi

if [ "$ALL" = false ]; then
    if [ -z "$NAME" ] || [ -z "$NAMESPACE" ]; then
        echo "Error: Both --name and --namespace are required for single-workbench mode."
        usage
    fi
fi

# ──────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────
case "$COMMAND" in
    patch)
        confirm_patch
        if [ "$ALL" = true ]; then
            process_all patch_workbench
        else
            patch_workbench "$NAME" "$NAMESPACE"
        fi
        ;;
    cleanup)
        confirm_cleanup
        if [ "$ALL" = true ]; then
            process_all cleanup_workbench
        else
            cleanup_workbench "$NAME" "$NAMESPACE"
        fi
        ;;
    verify)
        if [ "$ALL" = true ]; then
            process_all verify_workbench
        else
            verify_workbench "$NAME" "$NAMESPACE"
        fi
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        usage
        ;;
esac
