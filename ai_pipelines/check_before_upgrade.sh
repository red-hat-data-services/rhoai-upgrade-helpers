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
RHOAI_UPGRADE_BACKUP_DIR="${RHOAI_UPGRADE_BACKUP_DIR:-/tmp/rhoai-upgrade-backup}"
STATE_FILE="${RHOAI_UPGRADE_BACKUP_DIR}/ai_pipelines/dspa_pre_upgrade_pods.json"
mkdir -p "${RHOAI_UPGRADE_BACKUP_DIR}/ai_pipelines"

# Initialize tracking variables (populated in Step 2)
initial_v1alpha1=""
custom_roles=""
overall_rc=0

# Returns a compact JSON object for all pods matching a given prefix in the pre-fetched pod data.
# Groups by prefix so post-upgrade comparison works even if pod names change (new ReplicaSet suffix).
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

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Capture pre-upgrade pod health state
# ─────────────────────────────────────────────────────────────────────────────
echo '################################################################################'
echo "> Step 1: Pre-Upgrade DSPA Pod Health Check"
echo "> State will be saved to: ${STATE_FILE}"
echo '################################################################################'

dspas=$(kubectl get "$DSPA_RESOURCE" -A -o json | jq -c '
  .items[] |
  select(.apiVersion == "datasciencepipelinesapplications.opendatahub.io/v1") |
  {dspa_name: .metadata.name, namespace: .metadata.namespace}')

if [[ -z "$dspas" ]]; then
    echo "> No v1 DSPAs found. Skipping pod health capture."
    jq -n --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{captured_at: $ts, dspas: []}' > "$STATE_FILE"
    echo "> Pre-upgrade state saved to: ${STATE_FILE}"
    echo '################################################################################'
else
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    dspa_index=0

    while IFS= read -r dspa; do
        dspa_name=$(echo "$dspa" | jq -r '.dspa_name')
        namespace=$(echo "$dspa" | jq -r '.namespace')

        echo ""
        echo "> DSPA: ${dspa_name} | Namespace: ${namespace}"

        pod_data=$(kubectl get pods -n "$namespace" -o json)
        pod_groups_json="[]"
        dspa_rc=0

        for prefix in "ds-pipeline-${dspa_name}" "mariadb-${dspa_name}"; do
            echo "  Checking pods with prefix '${prefix}'..."

            group=$(get_pod_group "$pod_data" "$prefix")
            pod_groups_json=$(echo "$pod_groups_json" | jq --argjson g "$group" '. + [$g]')

            pods_found=$(echo "$group" | jq -r '.pods_found')

            if [[ "$pods_found" == "false" ]]; then
                echo "    [WARN] No pods found"
                dspa_rc=1
            else
                while IFS= read -r pod; do
                    pod_name=$(echo "$pod" | jq -r '.name')
                    phase=$(echo "$pod" | jq -r '.phase')
                    ready=$(echo "$pod" | jq -r '.ready')
                    healthy=$(echo "$pod" | jq -r '.healthy')

                    if [[ "$healthy" == "true" ]]; then
                        echo "    [OK]   ${pod_name} (Running, Ready)"
                    else
                        echo "    [FAIL] ${pod_name} (Phase: ${phase}, Ready: ${ready})"
                        dspa_rc=1
                    fi
                done < <(echo "$group" | jq -c '.pods[]')
            fi
        done

        [[ $dspa_rc -ne 0 ]] && overall_rc=1

        jq -n \
            --arg name "$dspa_name" \
            --arg ns "$namespace" \
            --argjson groups "$pod_groups_json" \
            '{dspa_name: $name, namespace: $ns, pod_groups: $groups}' \
            > "${tmp_dir}/dspa_${dspa_index}.json"

        dspa_index=$((dspa_index + 1))
    done <<< "$dspas"

    # Combine all per-DSPA files into a single state file
    jq -s --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '{captured_at: $ts, dspas: .}' \
        "${tmp_dir}"/dspa_*.json > "$STATE_FILE"

    echo ""
    echo "> Pre-upgrade state saved to: ${STATE_FILE}"
    echo '################################################################################'
    if [[ $overall_rc -eq 0 ]]; then
        echo "> Pre-upgrade: All DSPA pods are healthy"
    else
        echo "> Pre-upgrade: One or more DSPA pods are unhealthy or missing"
    fi
    echo '################################################################################'
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Fix deprecated v1alpha1 API versions and flag custom role issues
# ─────────────────────────────────────────────────────────────────────────────
echo '################################################################################'
echo "> Step 2: Checking for deprecated DSPA API versions and custom roles"
echo '################################################################################'

v1alpha1Versions=$(kubectl get "$DSPA_RESOURCE" -A -o json | jq -r '
  .items[] |
  select(.apiVersion == "datasciencepipelinesapplications.opendatahub.io/v1alpha1") |
  .metadata.name')

custom_roles=$(kubectl get roles -A -o json | jq -r '
  .items[] |
  select(
    (.metadata.namespace | test("kube-system|default|openshift|redhat-ods-.*") | not) and
    (.metadata.name | test("ds-pipeline-.*|pipeline-runner-.*") | not) and
    ([.rules[]?.apiGroups[]? == "route.openshift.io"] | any) and
    (
      [ .rules[]?.resources[]? == "datasciencepipelinesapplications/api" ] | any | not
    )
  ) | .metadata.name')

initial_v1alpha1="$v1alpha1Versions"

if [[ -n "$v1alpha1Versions" ]]; then
    max_retries=10
    retries=0
    while [[ -n "$v1alpha1Versions" && $retries -lt $max_retries ]]; do
        if [[ $retries -gt 0 ]]; then
            sleep_time=$(( 2 ** (retries - 1) < 30 ? 2 ** (retries - 1) : 30 ))
            echo "> Retry ${retries}/${max_retries}: waiting ${sleep_time}s before next attempt..."
            sleep "$sleep_time"
        fi
        echo "> Deprecated DSPA api version v1alpha1 found, fixing...."
        kubectl get "$DSPA_RESOURCE" -A -o json \
            | jq -c '
             .items[] |
             select(.apiVersion=="datasciencepipelinesapplications.opendatahub.io/v1alpha1") |
             del(
               .metadata.creationTimestamp,
               .metadata.generation,
               .metadata.managedFields,
               .metadata.resourceVersion,
               .metadata.uid,
               .status
             ) |
             .apiVersion = "datasciencepipelinesapplications.opendatahub.io/v1" |
             .kind = "DataSciencePipelinesApplication"
            ' | while read -r obj; do
             echo "$obj" | kubectl apply -f -
            done
        v1alpha1Versions=$(kubectl get "$DSPA_RESOURCE" -A -o json | jq -r '
          .items[] |
          select(.apiVersion == "datasciencepipelinesapplications.opendatahub.io/v1alpha1") |
          .metadata.name')
        retries=$((retries + 1))
    done
    if [[ -n "$v1alpha1Versions" ]]; then
        echo "> ERROR: Failed to migrate all v1alpha1 resources after $max_retries attempts. Please investigate manually."
        exit 1
    fi
    echo "> All v1alpha1 DSPAs successfully migrated to v1"
fi

if [[ -n "$custom_roles" ]]; then
    echo "> Custom roles found that may need updating, please reach out to your teams asking which roles are being used for AI Pipelines and under which project, and update those roles to include \`datasciencepipelinesapplications/api\` subresource by running \`update_dsp_role.sh\` script with parameters ROLE_NAME, NAMESPACE, DSPA_NAME, VERBS"
    echo "> Roles:"
    echo "$custom_roles" | while IFS= read -r role; do
        echo "    - ${role}"
    done
fi

echo '################################################################################'

if [[ -z "$initial_v1alpha1" && -z "$custom_roles" ]]; then
    echo "> No deprecated API versions or custom roles found. No need to do anything, proceed with your upgrade."
    echo '################################################################################'
fi

exit $overall_rc
