#!/bin/bash

set -o pipefail
set -u

# Validate prerequisites
for cmd in kubectl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "> ERROR: Required command '${cmd}' not found. Please install it and ensure it is in PATH."
        exit 1
    fi
done

DSPA_RESOURCE="datasciencepipelinesapplications.datasciencepipelinesapplications.opendatahub.io"
STATE_FILE="${DSPA_STATE_FILE:-/tmp/dspa_pre_upgrade_pods.json}"
WAIT_TIMEOUT="${DSPA_WAIT_TIMEOUT:-120}"
POLL_INTERVAL=15

# Returns a compact JSON object for all pods matching a given prefix.
get_pod_group() {
    local pod_data="$1"
    local prefix="$2"

    echo "$pod_data" | jq -c --arg prefix "$prefix" '
        ([ .items[] | select(.metadata.name | startswith($prefix)) ]) as $matching |
        {
            prefix: $prefix,
            pods_found: ($matching | length > 0),
            pods: [
                $matching[] | {
                    name: .metadata.name,
                    phase: (.status.phase // "Unknown"),
                    ready: ((.status.conditions // []) | map(select(.type == "Ready")) | first | .status // "Unknown"),
                    healthy: (
                        (.status.phase == "Running") and
                        ((.status.conditions // []) | map(select(.type == "Ready")) | first | .status == "True")
                    )
                }
            ]
        } | . + {
            all_healthy: (.pods_found and (.pods | map(.healthy) | all))
        }
    '
}

# Returns 0 if every pod group that was healthy pre-upgrade is now healthy.
# Pod groups that were already unhealthy pre-upgrade are ignored (pre-existing issue).
check_all_recovered() {
    local pre_dspas="$1"

    while IFS= read -r dspa; do
        local dspa_name namespace
        dspa_name=$(echo "$dspa" | jq -r '.dspa_name')
        namespace=$(echo "$dspa" | jq -r '.namespace')

        local pod_data
        pod_data=$(kubectl get pods -n "$namespace" -o json) || return 1

        while IFS= read -r group; do
            local prefix pre_healthy
            prefix=$(echo "$group" | jq -r '.prefix')
            pre_healthy=$(echo "$group" | jq -r '.all_healthy')

            if [[ "$pre_healthy" == "true" ]]; then
                local cur_healthy
                cur_healthy=$(get_pod_group "$pod_data" "$prefix" | jq -r '.all_healthy')
                if [[ "$cur_healthy" != "true" ]]; then
                    return 1
                fi
            fi
        done < <(echo "$dspa" | jq -c '.pod_groups[]')
    done < <(echo "$pre_dspas" | jq -c '.[]')

    return 0
}

# Prints comparison output. Verbose only for [FAIL] (healthy pre-upgrade, unhealthy post-upgrade).
# [OK], [IMPROVED], and [WARN] emit a single summary line each.
# Returns 1 if any pod group degraded compared to pre-upgrade state.
print_comparison() {
    local pre_dspas="$1"
    local overall_rc=0

    while IFS= read -r dspa; do
        local dspa_name namespace
        dspa_name=$(echo "$dspa" | jq -r '.dspa_name')
        namespace=$(echo "$dspa" | jq -r '.namespace')

        echo ""
        echo "> DSPA: ${dspa_name} | Namespace: ${namespace}"

        local pod_data
        pod_data=$(kubectl get pods -n "$namespace" -o json)

        while IFS= read -r group; do
            local prefix pre_healthy
            prefix=$(echo "$group" | jq -r '.prefix')
            pre_healthy=$(echo "$group" | jq -r '.all_healthy')

            local cur_group cur_healthy cur_pods_found
            cur_group=$(get_pod_group "$pod_data" "$prefix")
            cur_healthy=$(echo "$cur_group" | jq -r '.all_healthy')
            cur_pods_found=$(echo "$cur_group" | jq -r '.pods_found')

            if [[ "$cur_healthy" == "true" ]]; then
                if [[ "$pre_healthy" == "true" ]]; then
                    echo "  [OK]       ${prefix}"
                else
                    echo "  [IMPROVED] ${prefix} (was unhealthy pre-upgrade, now healthy)"
                fi
            elif [[ "$pre_healthy" == "false" ]]; then
                # Pre-existing issue — state did not change, not a regression
                echo "  [WARN]     ${prefix} (unchanged unhealthy state, pre-existing issue)"
            else
                # Degraded: was healthy pre-upgrade, unhealthy now — print pod details
                echo "  [FAIL]     ${prefix}"
                if [[ "$cur_pods_found" == "true" ]]; then
                    while IFS= read -r pod; do
                        local pod_name phase ready healthy
                        pod_name=$(echo "$pod" | jq -r '.name')
                        phase=$(echo "$pod" | jq -r '.phase')
                        ready=$(echo "$pod" | jq -r '.ready')
                        healthy=$(echo "$pod" | jq -r '.healthy')

                        if [[ "$healthy" == "true" ]]; then
                            echo "    [OK]   ${pod_name} (Running, Ready)"
                        else
                            echo "    [FAIL] ${pod_name} (Phase: ${phase}, Ready: ${ready})"
                        fi
                    done < <(echo "$cur_group" | jq -c '.pods[]')
                else
                    echo "    [MISSING] No pods found post-upgrade"
                fi
                overall_rc=1
            fi

        done < <(echo "$dspa" | jq -c '.pod_groups[]')
    done < <(echo "$pre_dspas" | jq -c '.[]')

    return $overall_rc
}

echo '################################################################################'
echo "> Post-Upgrade DSPA Pod Health Check"
echo '################################################################################'

if [[ ! -f "$STATE_FILE" ]]; then
    echo "> ERROR: Pre-upgrade state file not found: ${STATE_FILE}"
    echo "> Please run check_before_upgrade.sh before upgrading"
    echo '################################################################################'
    exit 1
fi

pre_state=$(cat "$STATE_FILE")
captured_at=$(echo "$pre_state" | jq -r '.captured_at')
pre_dspas=$(echo "$pre_state" | jq -c '.dspas')

echo "> Pre-upgrade state captured at: ${captured_at}"
echo ""

# Initial check — no wait. If nothing degraded, exit immediately.
if check_all_recovered "$pre_dspas"; then
    echo "> All DSPA pods are healthy (no degradation detected post-upgrade)"
    echo '################################################################################'
    exit 0
fi

# Degradation detected — give pods time to recover before concluding.
echo "> Degradation detected. Waiting up to ${WAIT_TIMEOUT}s for pods to recover (polling every ${POLL_INTERVAL}s)..."
echo ""

elapsed=0
recovered=false

while [[ $elapsed -lt $WAIT_TIMEOUT ]]; do
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    remaining=$((WAIT_TIMEOUT - elapsed))

    if check_all_recovered "$pre_dspas"; then
        echo "> All previously-healthy pods recovered (${elapsed}s elapsed)"
        recovered=true
        break
    fi

    if [[ $remaining -gt 0 ]]; then
        echo "> Not yet fully recovered, retrying in ${POLL_INTERVAL}s... (${remaining}s remaining)"
    fi
done

if [[ "$recovered" == "true" ]]; then
    echo ""
    echo '################################################################################'
    print_comparison "$pre_dspas"
    echo ""
    echo '################################################################################'
    echo "> Post-upgrade: All DSPA pods recovered successfully"
    echo '################################################################################'
    exit 0
fi

echo "> Wait timeout reached (${WAIT_TIMEOUT}s). Proceeding with final health comparison..."

echo ""
echo '################################################################################'
echo "> Pre vs Post-Upgrade Comparison:"

overall_rc=0
if ! print_comparison "$pre_dspas"; then
    overall_rc=1
fi

echo ""
echo '################################################################################'
if [[ $overall_rc -eq 0 ]]; then
    echo "> Post-upgrade: All DSPA pods are in an equal/better state than before upgrade"
else
    echo "> Post-upgrade: One or more DSPA pods degraded compared to pre-upgrade state"
fi
echo '################################################################################'

exit $overall_rc
