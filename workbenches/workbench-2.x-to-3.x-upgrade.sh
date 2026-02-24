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
#   verify   - Verify migration and/or cleanup status
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
  cleanup  Remove leftover OAuth resources (Route, Service, Secrets,
           OAuthClient) that are no longer needed after migration.
  verify   Check migration and/or cleanup state.

Options:
  --name NAME              Notebook name   (required for single-workbench mode)
  --namespace NAMESPACE    Notebook namespace (required for single-workbench mode)
  --all                    Operate on every notebook in the cluster
  --phase PHASE            Verify phase: migration|cleanup|all (verify command only;
                           default: migration)
  -y, --yes                Skip confirmation prompts (for automation / CI)

One of "--name NAME --namespace NAMESPACE" or "--all" must be provided.

Examples:
  $(basename "$0") patch   --name my-wb --namespace my-ns
  $(basename "$0") cleanup --all
  $(basename "$0") verify  --name my-wb --namespace my-ns
  $(basename "$0") verify  --all
  $(basename "$0") verify  --all --phase cleanup
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
║  cluster (Routes, Service, Secrets, OAuthClients).             ║
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

# Ask whether cleanup should continue for a single workbench when pre-checks fail.
# Returns:
#   0 -> continue cleanup
#   1 -> skip cleanup for this workbench
ask_cleanup_continue_or_skip() {
    local name="$1"
    local namespace="$2"
    local answer=""

    if [ "${SKIP_CONFIRM:-false}" = true ]; then
        echo "  --yes provided: proceeding with cleanup for '$name' in '$namespace' despite failed pre-checks."
        return 0
    fi

    echo ""
    if [ -r /dev/tty ]; then
        read -r -p "Pre-checks failed for '$name' in '$namespace'. Type 'yes' to continue cleanup, or press Enter to skip: " answer < /dev/tty
    else
        echo "  No interactive terminal detected and --yes not set; skipping cleanup for safety."
        return 1
    fi

    if [ "$answer" = "yes" ]; then
        return 0
    fi
    return 1
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
      (
        # Ensure the annotations object exists before adding nested keys.
        if ((.metadata.annotations // null) == null)
        then {"op":"add","path":"/metadata/annotations","value":{}}
        else empty
        end
      ),
      {"op":"add","path":"/metadata/annotations/notebooks.opendatahub.io~1inject-auth","value":"true"},
      (
        if (.metadata.annotations // {} | has("notebooks.opendatahub.io/inject-oauth"))
        then {"op":"remove","path":"/metadata/annotations/notebooks.opendatahub.io~1inject-oauth"}
        else empty
        end
      ),
      (
        if (.metadata.annotations // {} | has("notebooks.opendatahub.io/oauth-logout-url"))
        then {"op":"remove","path":"/metadata/annotations/notebooks.opendatahub.io~1oauth-logout-url"}
        else empty
        end
      ),
      (
        .spec.template.spec.containers // [] | to_entries[] |
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
        .spec.template.spec.containers // [] | to_entries[] |
        .key as $ci |
        .value.env // [] | to_entries[] |
        select(.value.name == "NOTEBOOK_ARGS") |
        select((.value.value // "") | test("--ServerApp\\.tornado_settings=")) |
        .key as $ei |
        ((.value.value // "") | gsub("[\\n\\r\\t ]*--ServerApp\\.tornado_settings=[^\\n]*"; "")) as $new_val |
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
    echo "[Pre-check] Running verify checks before cleanup..."

    if check_workbench_migration "$name" "$namespace" true; then
        echo "  Pre-check result: all verification checks passed."
    else
        echo "  Pre-check result: one or more verification checks failed."
        if ask_cleanup_continue_or_skip "$name" "$namespace"; then
            echo "  Continuing cleanup for '$name' in '$namespace' by user choice."
        else
            echo "  Skipping cleanup for '$name' in '$namespace'."
            return 0
        fi
    fi

    echo "[1/4] Removing Route..."
    oc delete route "$name" -n "$namespace" --ignore-not-found

    echo "[2/4] Removing Service..."
    oc delete service "$name" "${name}-tls" -n "$namespace" --ignore-not-found

    echo "[3/4] Removing Secrets..."
    oc delete secret "${name}-oauth-client" "${name}-oauth-config" "${name}-tls" -n "$namespace" --ignore-not-found

    echo "[4/4] Removing OAuthClient: ${name}-${namespace}-oauth-client"
    oc delete oauthclient "${name}-${namespace}-oauth-client" --ignore-not-found

    echo "=========================================================="
    echo " Cleanup complete for '$name' in '$namespace'."
    echo "=========================================================="
}

# Run migration checks used by verify and cleanup pre-check.
#   $1 = notebook name
#   $2 = namespace
#   $3 = verbose output (true/false)
# Returns:
#   0 -> all checks passed
#   1 -> one or more checks failed
check_workbench_migration() {
    local name="$1"
    local namespace="$2"
    local verbose="${3:-false}"
    local pass=true

    # Check inject-auth annotation (should be "true")
    AUTH=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.metadata.annotations.notebooks\.opendatahub\.io/inject-auth}' 2>/dev/null)
    if [ "$AUTH" = "true" ]; then
        if [ "$verbose" = true ]; then
            echo "  PASS: inject-auth annotation is set to 'true'"
        fi
    else
        if [ "$verbose" = true ]; then
            echo "  FAIL: inject-auth annotation missing or incorrect (found: '$AUTH')"
        fi
        pass=false
    fi

    # Check inject-oauth annotation (should NOT exist)
    OAUTH=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.metadata.annotations.notebooks\.opendatahub\.io/inject-oauth}' 2>/dev/null)
    if [ -z "$OAUTH" ]; then
        if [ "$verbose" = true ]; then
            echo "  PASS: Legacy inject-oauth annotation removed"
        fi
    else
        if [ "$verbose" = true ]; then
            echo "  FAIL: Legacy inject-oauth annotation still exists: '$OAUTH'"
        fi
        pass=false
    fi

    # Check that --ServerApp.tornado_settings is removed from NOTEBOOK_ARGS
    NB_ARGS=$(oc get notebook "$name" -n "$namespace" -o json 2>/dev/null \
        | jq -r '.spec.template.spec.containers[].env // [] | .[] | select(.name == "NOTEBOOK_ARGS") | .value' 2>/dev/null)
    if echo "$NB_ARGS" | grep -q -- "--ServerApp.tornado_settings="; then
        if [ "$verbose" = true ]; then
            echo "  FAIL: --ServerApp.tornado_settings still present in NOTEBOOK_ARGS"
        fi
        pass=false
    else
        if [ "$verbose" = true ]; then
            echo "  PASS: --ServerApp.tornado_settings removed from NOTEBOOK_ARGS"
        fi
    fi

    # Check sidecar containers
    CONTAINERS=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null)

    if echo "$CONTAINERS" | grep -q "kube-rbac-proxy"; then
        if [ "$verbose" = true ]; then
            echo "  PASS: kube-rbac-proxy sidecar container present (RHOAI 3.x)"
        fi
    else
        if [ "$verbose" = true ]; then
            echo "  FAIL: kube-rbac-proxy sidecar container missing"
        fi
        pass=false
    fi

    if echo "$CONTAINERS" | grep -q "oauth-proxy"; then
        if [ "$verbose" = true ]; then
            echo "  FAIL: Legacy oauth-proxy sidecar still present (RHOAI 2.x)"
        fi
        pass=false
    else
        if [ "$verbose" = true ]; then
            echo "  PASS: Legacy oauth-proxy sidecar removed"
        fi
    fi

    if [ "$verbose" = true ]; then
        echo "  Containers found: $CONTAINERS"
    fi

    if [ "$pass" = true ]; then
        return 0
    else
        return 1
    fi
}

# Run cleanup checks to confirm legacy resources are removed.
#   $1 = notebook name
#   $2 = namespace
check_workbench_cleanup() {
    local name="$1"
    local namespace="$2"
    local verbose="${3:-false}"
    local pass=true

    if oc get route "$name" -n "$namespace" >/dev/null 2>&1; then
        if [ "$verbose" = true ]; then
            echo "  FAIL: Route '$name' still exists"
        fi
        pass=false
    else
        if [ "$verbose" = true ]; then
            echo "  PASS: Route '$name' is removed"
        fi
    fi

    if oc get service "${name}-tls" -n "$namespace" >/dev/null 2>&1; then
        if [ "$verbose" = true ]; then
            echo "  FAIL: Service '${name}-tls' still exists"
        fi
        pass=false
    else
        if [ "$verbose" = true ]; then
            echo "  PASS: Service '${name}-tls' is removed"
        fi
    fi

    if oc get secret "${name}-oauth-client" -n "$namespace" >/dev/null 2>&1; then
        if [ "$verbose" = true ]; then
            echo "  FAIL: Secret '${name}-oauth-client' still exists"
        fi
        pass=false
    else
        if [ "$verbose" = true ]; then
            echo "  PASS: Secret '${name}-oauth-client' is removed"
        fi
    fi

    if oc get secret "${name}-oauth-config" -n "$namespace" >/dev/null 2>&1; then
        if [ "$verbose" = true ]; then
            echo "  FAIL: Secret '${name}-oauth-config' still exists"
        fi
        pass=false
    else
        if [ "$verbose" = true ]; then
            echo "  PASS: Secret '${name}-oauth-config' is removed"
        fi
    fi

    if oc get secret "${name}-tls" -n "$namespace" >/dev/null 2>&1; then
        if [ "$verbose" = true ]; then
            echo "  FAIL: Secret '${name}-tls' still exists"
        fi
        pass=false
    else
        if [ "$verbose" = true ]; then
            echo "  PASS: Secret '${name}-tls' is removed"
        fi
    fi

    if oc get oauthclient "${name}-${namespace}-oauth-client" >/dev/null 2>&1; then
        if [ "$verbose" = true ]; then
            echo "  FAIL: OAuthClient '${name}-${namespace}-oauth-client' still exists"
        fi
        pass=false
    else
        if [ "$verbose" = true ]; then
            echo "  PASS: OAuthClient '${name}-${namespace}-oauth-client' is removed"
        fi
    fi

    if [ "$pass" = true ]; then
        return 0
    else
        return 1
    fi
}

# Verify migration and/or cleanup status for a single notebook.
#   $1 = notebook name
#   $2 = namespace
verify_workbench() {
    local name="$1"
    local namespace="$2"
    local pass=true

    echo "=== Verifying Notebook: $name in $namespace ==="

    case "${VERIFY_PHASE:-migration}" in
        migration)
            echo "  Phase: migration"
            check_workbench_migration "$name" "$namespace" true || pass=false
            [ "$pass" = true ] && echo "=== RESULT: ALL CHECKS PASSED ===" || echo "=== RESULT: SOME CHECKS FAILED ==="
            ;;
        cleanup)
            echo "  Phase: cleanup"
            check_workbench_cleanup "$name" "$namespace" true || pass=false
            [ "$pass" = true ] && echo "=== RESULT: ALL CHECKS PASSED ===" || echo "=== RESULT: SOME CHECKS FAILED ==="
            ;;
        all)
            echo "  Phase: migration"
            if ! check_workbench_migration "$name" "$namespace" true; then
                pass=false
            fi
            echo "  Phase: cleanup"
            if ! check_workbench_cleanup "$name" "$namespace" true; then
                pass=false
            fi
            if [ "$pass" = true ]; then
                echo "=== RESULT: ALL CHECKS PASSED ==="
            else
                echo "=== RESULT: SOME CHECKS FAILED ==="
            fi
            ;;
        *)
            echo "Error: Unsupported verify phase '${VERIFY_PHASE}'."
            exit 1
            ;;
    esac

    if [ "$pass" = false ]; then
        return 1
    fi
    echo ""
}

# ──────────────────────────────────────────────
# Batch helper — run a function for every notebook
# ──────────────────────────────────────────────
process_all() {
    local func="$1"
    local total=0
    local failed=0

    while read -r nb_name nb_namespace; do
        total=$((total + 1))
        if ! "$func" "$nb_name" "$nb_namespace"; then
            failed=$((failed + 1))
        fi
    done < <(
        oc get notebooks --all-namespaces \
            -o custom-columns=NAME:.metadata.name,NS:.metadata.namespace \
            --no-headers
    )

    if [ "$failed" -gt 0 ]; then
        echo ""
        echo "Processed $total notebook(s): $failed failed."
        return 1
    fi

    echo ""
    echo "Processed $total notebook(s): all succeeded."
    return 0
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
VERIFY_PHASE="migration"
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
        --phase)
            VERIFY_PHASE="$2"
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

if [ "$COMMAND" != "verify" ] && [ "$VERIFY_PHASE" != "migration" ]; then
    echo "Error: --phase is only supported with the verify command."
    usage
fi

if [ "$COMMAND" = "verify" ]; then
    case "$VERIFY_PHASE" in
        migration|cleanup|all) ;;
        *)
            echo "Error: Invalid --phase '$VERIFY_PHASE'. Use migration, cleanup, or all."
            usage
            ;;
    esac
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
