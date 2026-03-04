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
# It is recommended to stop all affected workbenches BEFORE running the
# patch command to avoid data loss or disruption to users.
#
# As a safety net, the script will automatically stop any workbench that
# is still running before patching it (by adding the
# kubeflow-resource-stopped annotation and waiting for the pod and
# StatefulSet to terminate). After patching, workbenches that were
# stopped by the script are restarted automatically.
# Use --skip-stop to disable this automatic stop/restart behaviour.
#
# Main workflow commands (run in order: patch → verify → cleanup):
#   list              - Identify legacy / migrated / invalid workbenches
#   patch             - Patch notebook resources for 3.x auth model
#                       (use --with-cleanup to run cleanup immediately after patch)
#   verify            - Verify migration and/or cleanup status
#   cleanup           - Remove stale OAuth routes, secrets, and OAuthClients
#
# Troubleshooting commands (run only if odh-cli pre-check fails for kueue label on notebook):
#   attach-kueue-label - Add kueue queue-name label to notebooks in kueue-managed namespaces
#
# Examples:
#   ./workbench-2.x-to-3.x-upgrade.sh list    --all
#   ./workbench-2.x-to-3.x-upgrade.sh list    --name my-wb --namespace my-ns
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

Main workflow commands (run in order: patch → verify → cleanup):
  list              Identify legacy, migrated, and invalid workbenches by inspecting
                    Notebook CR annotations. Use this before migrating to see which
                    workbenches still need to be patched.
  patch             Patch notebook CR for the 3.x auth model (removes oauth-proxy
                    sidecar, adds inject-auth annotation, deletes StatefulSet).
                    WARNING: Running workbenches will be restarted — stop them first.
                    As a safety net, any still-running workbench is stopped
                    automatically before patching and restarted afterwards.
                    Use --skip-stop to disable this automatic stop/restart.
                    Use --with-cleanup to run cleanup automatically after patch.
  verify            Check migration and/or cleanup state.
  cleanup           Remove leftover OAuth resources (Route, Service, Secrets,
                    OAuthClient) that are no longer needed after migration.

Troubleshooting commands (run only if odh-cli pre-check fails for kueue label on notebook):
  attach-kueue-label Add 'kueue.x-k8s.io/queue-name' label to notebooks in
                    kueue-managed namespaces. Skips notebooks that already
                    have the label. Use --queue-name to specify a custom value
                    (default: 'default').

Options:
  --name NAME              Notebook name   (required for single-workbench mode)
  --namespace NAMESPACE    Notebook namespace (required for single-workbench mode)
  --all                    Operate on every notebook in the cluster
  --phase PHASE            Verify phase: migration|cleanup|all (verify command only;
                           default: migration)
  --skip-stop              Skip the automatic stop/restart of workbenches before
                           and after patching (use only if you are managing the
                           workbench lifecycle manually)
  --only-stopped           Only patch workbenches that are already stopped
                           (patch command only; skips running workbenches)
  --with-cleanup           Run cleanup automatically after a successful patch
                           (patch command only)
  -y, --yes                Skip confirmation prompts (for automation / CI)
  --queue-name NAME        Queue name value for attach-kueue-label (default: 'default')

One of "--name NAME --namespace NAMESPACE" or "--all" must be provided.

Examples (main workflow):
  $(basename "$0") list    --all
  $(basename "$0") patch   --name my-wb --namespace my-ns
  $(basename "$0") patch   --name my-wb --namespace my-ns --with-cleanup
  $(basename "$0") patch   --all --skip-stop
  $(basename "$0") patch   --all --only-stopped
  $(basename "$0") cleanup --all
  $(basename "$0") verify  --name my-wb --namespace my-ns
  $(basename "$0") verify  --all
  $(basename "$0") verify  --all --phase cleanup

Examples (troubleshooting - only if odh-cli pre-check fails for kueue label on notebook):
  $(basename "$0") attach-kueue-label --all
  $(basename "$0") attach-kueue-label --all --queue-name my-queue
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

# EXIT trap for the patch command.  If the script exits unexpectedly while
# we have workbenches stopped, warn the user so they can restart them.
patch_exit_handler() {
    local exit_code=$?
    if [ -n "${STOPPED_BY_SCRIPT:-}" ] && [ -s "$STOPPED_BY_SCRIPT" ]; then
        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║  WARNING: Script exited before restarting these workbenches:   ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        while read -r wb_name wb_namespace; do
            echo "  - $wb_name  (namespace: $wb_namespace)"
        done < "$STOPPED_BY_SCRIPT"
        echo ""
        echo "  To restart them manually, remove the 'kubeflow-resource-stopped'"
        echo "  annotation from each notebook, e.g.:"
        echo "    oc annotate notebook <name> -n <namespace> kubeflow-resource-stopped-"
        echo ""
        rm -f "$STOPPED_BY_SCRIPT"
    fi
    rm -f "${KUEUE_WORKBENCHES_TO_CHECK:-}"
    return "$exit_code"
}

# Confirmation gate for the patch command.
confirm_patch() {
    if [ "$ONLY_STOPPED" = true ]; then
        cat <<'EOF'

╔════════════════════════════════════════════════════════════════╗
║                        *** NOTICE ***                          ║
║                                                                ║
║  You are about to PATCH notebook resources on this cluster     ║
║  with --only-stopped enabled.                                  ║
║                                                                ║
║  This operation will:                                          ║
║   - Only patch workbenches that are ALREADY STOPPED            ║
║   - Skip any workbenches that are currently running            ║
║   - Modify notebook CRs (annotations, containers, volumes)     ║
║   - Delete StatefulSets                                        ║
║   - Strip legacy OAuth-proxy configuration                     ║
║                                                                ║
║  Running workbenches will NOT be affected by this operation.   ║
╚════════════════════════════════════════════════════════════════╝
EOF
    elif [ "$SKIP_STOP" = true ]; then
        cat <<'EOF'

╔════════════════════════════════════════════════════════════════╗
║                        *** WARNING ***                         ║
║                                                                ║
║  You are about to PATCH notebook resources on this cluster     ║
║  with --skip-stop enabled (automatic stop/restart disabled).   ║
║                                                                ║
║  This operation will:                                          ║
║   - Modify notebook CRs (annotations, containers, volumes)     ║
║   - Delete StatefulSets, causing RUNNING workbenches to        ║
║     RESTART                                                    ║
║   - Strip legacy OAuth-proxy configuration                     ║
║                                                                ║
║  BEFORE PROCEEDING, make sure you have:                        ║
║   1. Notified RHOAI users to save all their data inside        ║
║      the workbenches                                           ║
║   2. Stopped all affected workbenches                          ║
║   3. Verified you are connected to the correct cluster         ║
║                                                                ║
║  RISK: Running this on active workbenches may cause DATA LOSS  ║
║  or DISRUPTION to users.                                       ║
╚════════════════════════════════════════════════════════════════╝
EOF
    else
        cat <<'EOF'

╔════════════════════════════════════════════════════════════════╗
║                        *** WARNING ***                         ║
║                                                                ║
║  You are about to PATCH notebook resources on this cluster.    ║
║                                                                ║
║  This operation will:                                          ║
║   - Modify notebook CRs (annotations, containers, volumes)     ║
║   - Delete StatefulSets                                        ║
║   - Strip legacy OAuth-proxy configuration                     ║
║                                                                ║
║  BEFORE PROCEEDING, make sure you have:                        ║
║   1. Notified RHOAI users to save all their data inside        ║
║      the workbenches                                           ║
║   2. Stopped all affected workbenches                          ║
║   3. Verified you are connected to the correct cluster         ║
║                                                                ║
║  RISK: Running this on active workbenches may cause DATA LOSS  ║
║  or DISRUPTION to users.                                       ║
║                                                                ║
║  SAFETY NET: Any still-running workbenches will be stopped     ║
║  automatically before patching and restarted afterwards.       ║
║  Use --skip-stop to disable this behaviour.                    ║
╚════════════════════════════════════════════════════════════════╝
EOF
    fi
    print_cluster_info
    if [ "$ALL" = true ]; then
        if [ "$ONLY_STOPPED" = true ]; then
            echo "  Target:  ALL STOPPED notebooks in the cluster"
        else
            echo "  Target:  ALL notebooks in the cluster"
        fi
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

# Delete a resource only when it exists, and report accurate status.
#   $1 = kind
#   $2 = name
#   $3 = namespace (optional for cluster-scoped resources)
delete_resource_if_present() {
    local kind="$1"
    local name="$2"
    local namespace="${3:-}"

    if [ -n "$namespace" ]; then
        if oc get "$kind" "$name" -n "$namespace" >/dev/null 2>&1; then
            oc delete "$kind" "$name" -n "$namespace" >/dev/null
            echo "  Deleted ${kind}/${name} in namespace '${namespace}'."
        else
            echo "  Already absent: ${kind}/${name} in namespace '${namespace}'."
        fi
    else
        if oc get "$kind" "$name" >/dev/null 2>&1; then
            oc delete "$kind" "$name" >/dev/null
            echo "  Deleted ${kind}/${name}."
        else
            echo "  Already absent: ${kind}/${name}."
        fi
    fi
}

# ──────────────────────────────────────────────
# Core functions (single workbench)
# ──────────────────────────────────────────────

# Stop a running workbench by annotating the Notebook CR with
# kubeflow-resource-stopped and waiting for the owning StatefulSet and
# its pod(s) to terminate.
# Workbenches that are already stopped (annotation present) are skipped.
# Workbenches that we actually stop are recorded in $STOPPED_BY_SCRIPT
# so they can be restarted after patching.
#   $1 = notebook name
#   $2 = namespace
stop_workbench() {
    local name="$1"
    local namespace="$2"

    # Check if the workbench is already stopped (annotation present)
    local stopped_annotation
    stopped_annotation=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.metadata.annotations.kubeflow-resource-stopped}' 2>/dev/null)

    if [ -n "$stopped_annotation" ]; then
        echo "  Workbench '$name' in '$namespace' is already stopped (since $stopped_annotation) — skipping."
        return 0
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    echo "Stopping workbench '$name' in namespace '$namespace'..."

    # Annotate the Notebook CR to request a stop
    oc annotate notebook "$name" -n "$namespace" \
        "kubeflow-resource-stopped=$timestamp" --overwrite
    echo "  Annotation 'kubeflow-resource-stopped=$timestamp' applied."

    # Record this workbench so we can restart it after patching
    echo "$name $namespace" >> "$STOPPED_BY_SCRIPT"

    # Find the StatefulSet owned by this Notebook (via ownerReferences)
    local sts_name
    sts_name=$(oc get statefulsets -n "$namespace" -o json | jq -r \
        --arg nb "$name" \
        '.items[] |
         select(.metadata.ownerReferences[]? |
                select(.kind == "Notebook" and .name == $nb)) |
         .metadata.name')

    if [ -z "$sts_name" ]; then
        echo "  No StatefulSet found for notebook '$name' — workbench may already be stopped."
        return 0
    fi

    echo "  Found StatefulSet: $sts_name"

    # Find pods owned by the StatefulSet (via ownerReferences)
    local pod_names
    pod_names=$(oc get pods -n "$namespace" -o json | jq -r \
        --arg sts "$sts_name" \
        '.items[] |
         select(.metadata.ownerReferences[]? |
                select(.kind == "StatefulSet" and .name == $sts)) |
         .metadata.name')

    # Wait for pods to terminate
    if [ -n "$pod_names" ]; then
        echo "  Waiting for pod(s) to terminate..."
        for pod in $pod_names; do
            echo "    Waiting for pod '$pod'..."
            oc wait --for=delete pod/"$pod" -n "$namespace" --timeout=120s 2>/dev/null || true
        done
    else
        echo "  No running pods found for StatefulSet '$sts_name'."
    fi

    # Wait for the StatefulSet to scale to 0 or be deleted
    echo "  Waiting for StatefulSet '$sts_name' to scale down..."
    local retries=0
    local max_retries=60
    while [ "$retries" -lt "$max_retries" ]; do
        local current_replicas
        current_replicas=$(oc get statefulset "$sts_name" -n "$namespace" \
            -o jsonpath='{.spec.replicas}' 2>/dev/null) || {
            echo "  StatefulSet '$sts_name' has been removed."
            break
        }
        if [ "$current_replicas" = "0" ]; then
            echo "  StatefulSet '$sts_name' scaled to 0 replicas."
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done

    if [ "$retries" -ge "$max_retries" ]; then
        echo "  WARNING: Timed out waiting for StatefulSet '$sts_name' to scale down."
        echo "  The workbench may not have stopped cleanly. Proceed with caution."
        return 1
    fi

    echo "  Workbench '$name' stopped successfully."
}

# Check if a workbench is stopped (has kubeflow-resource-stopped annotation).
#   $1 = notebook name
#   $2 = namespace
# Returns:
#   0 -> workbench is stopped
#   1 -> workbench is running (not stopped)
is_workbench_stopped() {
    local name="$1"
    local namespace="$2"
    local stopped_annotation

    stopped_annotation=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.metadata.annotations.kubeflow-resource-stopped}' 2>/dev/null)

    if [ -n "$stopped_annotation" ]; then
        return 0
    else
        return 1
    fi
}

# Restart a workbench that was stopped by the script by removing the
# kubeflow-resource-stopped annotation.
#   $1 = notebook name
#   $2 = namespace
restart_workbench() {
    local name="$1"
    local namespace="$2"

    echo "  Restarting workbench '$name' in namespace '$namespace'..."
    oc annotate notebook "$name" -n "$namespace" \
        "kubeflow-resource-stopped-"
    echo "  Annotation 'kubeflow-resource-stopped' removed — workbench will start."
}

# Patch a single notebook for the 3.x auth model.
#   $1 = notebook name
#   $2 = namespace
patch_workbench() {
    local name="$1"
    local namespace="$2"

    # If --only-stopped is set, skip workbenches that are not stopped
    if [ "$ONLY_STOPPED" = true ]; then
        if ! is_workbench_stopped "$name" "$namespace"; then
            echo "  Skipping '$name' in '$namespace' — workbench is running (--only-stopped)."
            return 0
        fi
    fi

    echo "Patching notebook '$name' in namespace '$namespace'..."

    # Track workbenches in Kueue-managed namespaces for post-patch check
    if [ "$SKIP_STOP" = true ] && is_namespace_kueue_managed "$namespace"; then
        echo "$name $namespace" >> "$KUEUE_WORKBENCHES_TO_CHECK"
    fi

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

    echo "[1/4] Ensuring Route is removed..."
    delete_resource_if_present route "$name" "$namespace"

    echo "[2/4] Ensuring Service is removed..."
    delete_resource_if_present service "${name}-tls" "$namespace"

    echo "[3/4] Ensuring Secrets are removed..."
    delete_resource_if_present secret "${name}-oauth-client" "$namespace"
    delete_resource_if_present secret "${name}-oauth-config" "$namespace"
    delete_resource_if_present secret "${name}-tls" "$namespace"

    echo "[4/4] Ensuring OAuthClient is removed..."
    delete_resource_if_present oauthclient "${name}-${namespace}-oauth-client"

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

    # Check sidecar containers first (needed for inject-oauth check)
    CONTAINERS=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null)

    local has_kube_rbac_proxy=false
    local has_oauth_proxy=false

    if echo "$CONTAINERS" | grep -q "kube-rbac-proxy"; then
        has_kube_rbac_proxy=true
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
        has_oauth_proxy=true
        if [ "$verbose" = true ]; then
            echo "  FAIL: Legacy oauth-proxy sidecar still present (RHOAI 2.x)"
        fi
        pass=false
    else
        if [ "$verbose" = true ]; then
            echo "  PASS: Legacy oauth-proxy sidecar removed"
        fi
    fi

    # Check inject-oauth annotation (only a failure if kube-rbac-proxy is missing or oauth-proxy still exists)
    OAUTH=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.metadata.annotations.notebooks\.opendatahub\.io/inject-oauth}' 2>/dev/null)
    if [ -z "$OAUTH" ]; then
        if [ "$verbose" = true ]; then
            echo "  PASS: Legacy inject-oauth annotation removed"
        fi
    else
        # Annotation exists - only considered migrated if kube-rbac-proxy is set AND oauth-proxy is removed
        if [ "$has_kube_rbac_proxy" = true ] && [ "$has_oauth_proxy" = false ]; then
            if [ "$verbose" = true ]; then
                echo "  WARN: Legacy inject-oauth annotation still exists: '$OAUTH' (but kube-rbac-proxy is set, considered migrated)"
            fi
        else
            if [ "$verbose" = true ]; then
                echo "  FAIL: Legacy inject-oauth annotation still exists: '$OAUTH'"
            fi
            pass=false
        fi
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

# Check if a namespace has the kueue.openshift.io/managed label set to 'true'.
#   $1 = namespace
# Returns:
#   0 -> namespace is kueue-managed
#   1 -> namespace is NOT kueue-managed
is_namespace_kueue_managed() {
    local namespace="$1"
    local managed_label

    managed_label=$(oc get namespace "$namespace" \
        -o jsonpath='{.metadata.labels.kueue\.openshift\.io/managed}' 2>/dev/null)

    if [ "$managed_label" = "true" ]; then
        return 0
    else
        return 1
    fi
}

# Check if a notebook's pod is stuck in Terminating state.
#   $1 = notebook name
#   $2 = namespace
# Returns:
#   0 -> pod is in Terminating state
#   1 -> pod is NOT in Terminating state (or doesn't exist)
is_pod_terminating() {
    local name="$1"
    local namespace="$2"
    local deletion_timestamp

    # Check if the pod exists and has a deletionTimestamp (indicating Terminating)
    deletion_timestamp=$(oc get pod "${name}-0" -n "$namespace" \
        -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)

    if [ -n "$deletion_timestamp" ]; then
        return 0
    else
        return 1
    fi
}

# Check tracked Kueue workbenches for pods stuck in Terminating state and warn.
# Reads from $KUEUE_WORKBENCHES_TO_CHECK file.
check_kueue_pods_terminating() {
    if [ ! -s "$KUEUE_WORKBENCHES_TO_CHECK" ]; then
        return 0
    fi

    local stuck_pods=()

    # Wait a few seconds to allow pods to start terminating
    sleep 3

    while read -r wb_name wb_namespace; do
        if is_pod_terminating "$wb_name" "$wb_namespace"; then
            stuck_pods+=("$wb_name $wb_namespace")
        fi
    done < "$KUEUE_WORKBENCHES_TO_CHECK"

    if [ ${#stuck_pods[@]} -gt 0 ]; then
        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║  WARNING: Kueue Finalizer Conflicts detected                   ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "  The following pods are stuck in Terminating state:"
        for entry in "${stuck_pods[@]}"; do
            local pod_name pod_ns
            pod_name=$(echo "$entry" | awk '{print $1}')
            pod_ns=$(echo "$entry" | awk '{print $2}')
            echo "    - ${pod_name}-0 (namespace: $pod_ns)"
        done
        echo ""
        echo "  This happens because the Kueue webhook may fail to reconcile"
        echo "  the workload when --skip-stop is used with running workbenches"
        echo "  in Kueue-managed namespaces."
        echo ""
        echo "  To resolve, remove the finalizer from the affected pod:"
        echo "    oc patch pod <pod-name> -n <namespace> -p '{\"metadata\":{\"finalizers\":null}}' --type=merge"
        echo ""
    fi
}

# Add kueue queue-name label to a notebook if missing.
#   $1 = notebook name
#   $2 = namespace
patch_kueue_label_workbench() {
    local name="$1"
    local namespace="$2"

    # First check if the namespace is kueue-managed
    if ! is_namespace_kueue_managed "$namespace"; then
        echo "  Skipping '$name' in '$namespace' — namespace is not kueue-managed."
        return 0
    fi

    # Check if the notebook already has the kueue.x-k8s.io/queue-name label
    local queue_label
    queue_label=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.metadata.labels.kueue\.x-k8s\.io/queue-name}' 2>/dev/null)

    if [ -n "$queue_label" ]; then
        echo "  Notebook '$name' in '$namespace' already has queue-name label: '$queue_label' — skipping."
        return 0
    fi

    echo "  Patching notebook '$name' in '$namespace' with kueue queue-name label..."
    oc label notebook "$name" -n "$namespace" \
        "kueue.x-k8s.io/queue-name=$QUEUE_NAME" --overwrite

    echo "  Label 'kueue.x-k8s.io/queue-name=$QUEUE_NAME' applied to '$name'."
}

# ──────────────────────────────────────────────
# List / check migration status
# ──────────────────────────────────────────────

# Check migration status of a single notebook.
#   $1 = notebook name
#   $2 = namespace
list_workbench() {
    local name="$1"
    local namespace="$2"
    local inject_oauth inject_auth containers status stopped_annotation state
    local has_kube_rbac_proxy=false has_oauth_proxy=false

    inject_oauth=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.metadata.annotations.notebooks\.opendatahub\.io/inject-oauth}' 2>/dev/null)
    inject_auth=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.metadata.annotations.notebooks\.opendatahub\.io/inject-auth}' 2>/dev/null)
    containers=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null)
    stopped_annotation=$(oc get notebook "$name" -n "$namespace" \
        -o jsonpath='{.metadata.annotations.kubeflow-resource-stopped}' 2>/dev/null)

    echo "$containers" | grep -q "kube-rbac-proxy" && has_kube_rbac_proxy=true
    echo "$containers" | grep -q "oauth-proxy" && has_oauth_proxy=true

    # Determine running state
    if [ -n "$stopped_annotation" ]; then
        state="Stopped (since $stopped_annotation)"
    else
        if oc get pod "${name}-0" -n "$namespace" >/dev/null 2>&1; then
            local pod_phase
            pod_phase=$(oc get pod "${name}-0" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
            case "$pod_phase" in
                Running)
                    state="Running"
                    ;;
                Pending)
                    state="Starting (pod pending)"
                    ;;
                *)
                    state="$pod_phase"
                    ;;
            esac
        else
            state="Starting (no pod yet)"
        fi
    fi

    echo "=== Notebook: $name  (namespace: $namespace) ==="
    echo "  State:                   $state"
    echo "  inject-oauth annotation: ${inject_oauth:-<not set>}"
    echo "  inject-auth  annotation: ${inject_auth:-<not set>}"
    echo "  kube-rbac-proxy sidecar: $has_kube_rbac_proxy"
    echo "  oauth-proxy sidecar:     $has_oauth_proxy"

    # Primary: sidecar-based status detection
    if [ "$has_kube_rbac_proxy" = true ] && [ "$has_oauth_proxy" = true ]; then
        echo "  Status: INVALID — both kube-rbac-proxy and oauth-proxy sidecars present"
    elif [ "$has_kube_rbac_proxy" = true ]; then
        # Migrated - kube-rbac-proxy is present, oauth-proxy is not
        if [ "$inject_oauth" = "true" ]; then
            echo "  Status: MIGRATED (leftover inject-oauth annotation)"
        else
            echo "  Status: MIGRATED"
        fi
    elif [ "$has_oauth_proxy" = true ]; then
        # oauth-proxy is present - check if unreconciled (inject-auth set but sidecar didn't switch)
        if [ "$inject_auth" = "true" ]; then
            echo "  Status: UNRECONCILED — inject-auth is set but oauth-proxy sidecar still present"
            echo "         Check notebook controller logs for reconciliation errors"
        else
            echo "  Status: LEGACY — needs migration to 3.x"
        fi
    else
        # Neither sidecar present
        echo "  Status: UNKNOWN — no auth sidecars found"
    fi
    echo ""
}

# Scan all notebooks on the cluster, classify each by migration status,
# and print a summary table. Uses a single API call for efficiency.
list_all_workbenches() {
    local json total legacy=0 migrated=0 invalid=0 unknown=0 unreconciled=0
    local running=0 stopped=0 starting=0

    json=$(oc get notebooks --all-namespaces -o json 2>/dev/null)
    total=$(echo "$json" | jq '.items | length')

    if [ "$total" -eq 0 ]; then
        echo "No notebooks found on the cluster."
        return 0
    fi

    echo ""
    echo "Scanning all notebooks on the cluster..."
    echo ""
    printf "  %-40s %-30s %-12s %s\n" "NAME" "NAMESPACE" "STATE" "STATUS"
    printf "  %-40s %-30s %-12s %s\n" "----" "---------" "-----" "------"

    while IFS='|' read -r nb_name nb_namespace oauth auth containers stopped_annotation; do
        local status state
        local has_kube_rbac_proxy=false has_oauth_proxy=false

        echo "$containers" | grep -q "kube-rbac-proxy" && has_kube_rbac_proxy=true
        echo "$containers" | grep -q "oauth-proxy" && has_oauth_proxy=true

        # Determine running state based on kubeflow-resource-stopped annotation and pod existence
        if [ -n "$stopped_annotation" ]; then
            state="Stopped"
            stopped=$((stopped + 1))
        else
            # Check if pod exists for this notebook
            if oc get pod "${nb_name}-0" -n "$nb_namespace" >/dev/null 2>&1; then
                local pod_phase
                pod_phase=$(oc get pod "${nb_name}-0" -n "$nb_namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
                case "$pod_phase" in
                    Running)
                        state="Running"
                        running=$((running + 1))
                        ;;
                    Pending)
                        state="Starting"
                        starting=$((starting + 1))
                        ;;
                    *)
                        state="$pod_phase"
                        ;;
                esac
            else
                state="Starting"
                starting=$((starting + 1))
            fi
        fi

        # Primary: sidecar-based status detection
        if [ "$has_kube_rbac_proxy" = true ] && [ "$has_oauth_proxy" = true ]; then
            status="INVALID"
            invalid=$((invalid + 1))
        elif [ "$has_kube_rbac_proxy" = true ]; then
            # Migrated - kube-rbac-proxy present, oauth-proxy not
            if [ "$oauth" = "true" ]; then
                status="MIGRATED (leftover annotation)"
            else
                status="MIGRATED (3.x)"
            fi
            migrated=$((migrated + 1))
        elif [ "$has_oauth_proxy" = true ]; then
            # oauth-proxy present - check if unreconciled
            if [ "$auth" = "true" ]; then
                status="UNRECONCILED (check logs)"
                unreconciled=$((unreconciled + 1))
            else
                status="LEGACY (2.x)"
                legacy=$((legacy + 1))
            fi
        else
            # Neither sidecar present
            status="UNKNOWN"
            unknown=$((unknown + 1))
        fi
        printf "  %-40s %-30s %-12s %s\n" "$nb_name" "$nb_namespace" "$state" "$status"
    done < <(echo "$json" | jq -r '.items[] | [
        .metadata.name,
        .metadata.namespace,
        (.metadata.annotations["notebooks.opendatahub.io/inject-oauth"] // ""),
        (.metadata.annotations["notebooks.opendatahub.io/inject-auth"] // ""),
        ([.spec.template.spec.containers[].name] | join(" ")),
        (.metadata.annotations["kubeflow-resource-stopped"] // "")
    ] | join("|")')

    echo ""
    echo "Summary:"
    echo "  Total notebooks:  $total"
    echo ""
    echo "  Migration status:"
    echo "    Legacy (2.x):     $legacy"
    echo "    Migrated (3.x):   $migrated"
    echo "    Unreconciled:     $unreconciled"
    echo "    Invalid state:    $invalid"
    echo "    Unknown:          $unknown"
    echo ""
    echo "  Running state:"
    echo "    Running:          $running"
    echo "    Stopped:          $stopped"
    echo "    Starting:         $starting"
    echo ""

    if [ "$legacy" -gt 0 ]; then
        echo "  WARNING: $legacy notebook(s) still need migration (LEGACY)."
    fi
    if [ "$unreconciled" -gt 0 ]; then
        echo "  ERROR:   $unreconciled notebook(s) are UNRECONCILED — inject-auth annotation is set but"
        echo "           oauth-proxy sidecar is still present. Check notebook controller logs."
    fi
    if [ "$invalid" -gt 0 ]; then
        echo "  ERROR:   $invalid notebook(s) are in an invalid state — review manually."
        echo "           Run '$(basename "$0") verify --name <name> --namespace <namespace> --phase migration' to review the migration status."
        echo "           Run '$(basename "$0") patch --name <name> --namespace <namespace>' to patch the notebook to the 3.x auth model."
    fi
    if [ "$legacy" -eq 0 ] && [ "$invalid" -eq 0 ]; then
        echo "  OK: All notebooks have been migrated."
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
SKIP_STOP=false
ONLY_STOPPED=false
WITH_CLEANUP=false
NAME=""
NAMESPACE=""
QUEUE_NAME="default"

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
        --skip-stop)
            SKIP_STOP=true
            shift
            ;;
        --only-stopped)
            ONLY_STOPPED=true
            shift
            ;;
        --with-cleanup)
            WITH_CLEANUP=true
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        --queue-name)
            QUEUE_NAME="$2"
            shift 2
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

if [ "$COMMAND" != "patch" ] && [ "$WITH_CLEANUP" = true ]; then
    echo "Error: --with-cleanup is only supported with the patch command."
    usage
fi

if [ "$COMMAND" != "patch" ] && [ "$ONLY_STOPPED" = true ]; then
    echo "Error: --only-stopped is only supported with the patch command."
    usage
fi

if [ "$ONLY_STOPPED" = true ] && [ "$SKIP_STOP" = true ]; then
    echo "Error: --only-stopped and --skip-stop cannot be combined."
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
    list)
        if [ "$ALL" = true ]; then
            list_all_workbenches
        else
            list_workbench "$NAME" "$NAMESPACE"
        fi
        ;;
    patch)
        confirm_patch

        # Temp file that tracks workbenches we stopped (so we can restart them).
        # Written to by stop_workbench(), read after patching.
        STOPPED_BY_SCRIPT=$(mktemp)
        # Temp file that tracks workbenches in Kueue-managed namespaces (for post-patch check).
        KUEUE_WORKBENCHES_TO_CHECK=$(mktemp)
        trap 'patch_exit_handler' EXIT

        if [ "$SKIP_STOP" = false ] && [ "$ONLY_STOPPED" = false ]; then
            echo ""
            echo "=== Stopping any still-running workbench(es) before patching ==="
            if [ "$ALL" = true ]; then
                process_all stop_workbench
            else
                stop_workbench "$NAME" "$NAMESPACE"
            fi
            echo ""
        fi

        if [ "$ALL" = true ]; then
            process_all patch_workbench
        else
            patch_workbench "$NAME" "$NAMESPACE"
        fi

        # Restart workbenches that were stopped by the script
        if [ -s "$STOPPED_BY_SCRIPT" ]; then
            echo ""
            echo "=== Restarting workbenches that were stopped for migration ==="
            while read -r wb_name wb_namespace; do
                restart_workbench "$wb_name" "$wb_namespace"
            done < "$STOPPED_BY_SCRIPT"
            echo ""
        fi

        if [ "$WITH_CLEANUP" = true ]; then
            echo "=== Running cleanup after patch (--with-cleanup) ==="
            confirm_cleanup
            if [ "$ALL" = true ]; then
                process_all cleanup_workbench
            else
                cleanup_workbench "$NAME" "$NAMESPACE"
            fi
        fi

        # Check for pods stuck in Terminating state in Kueue-managed namespaces
        check_kueue_pods_terminating

        rm -f "$STOPPED_BY_SCRIPT" "$KUEUE_WORKBENCHES_TO_CHECK"
        trap - EXIT
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
    attach-kueue-label)
        echo "=== Patching kueue queue-name labels ==="
        if [ "$ALL" = true ]; then
            process_all patch_kueue_label_workbench
        else
            patch_kueue_label_workbench "$NAME" "$NAMESPACE"
        fi
        echo "=== Kueue label patching complete ==="
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        usage
        ;;
esac
