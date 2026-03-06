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

usage() {
    echo "Usage: $0 ROLE_NAME NAMESPACE DSPA_NAME VERBS"
    echo ""
    echo "  ROLE_NAME   Name of the role to update"
    echo "  NAMESPACE   Namespace where the role exists"
    echo "  DSPA_NAME   Name of the DataSciencePipelinesApplication"
    echo "  VERBS       Comma-separated list of verbs (e.g. get,list,create)"
    echo ""
    echo "Example:"
    echo "  $0 my-role my-namespace my-dspa get,list,create"
    exit 1
}

if [[ $# -ne 4 ]]; then
    echo "> ERROR: Expected 4 arguments, got $#"
    echo ""
    usage
fi

ROLE_NAME="$1"
NAMESPACE="$2"
DSPA_NAME="$3"
VERBS="$4"

# Convert comma-separated VERBS into a JSON array: "get,list" -> ["get","list"]
verbs_json=$(echo "$VERBS" | jq -Rc 'split(",")')

echo '################################################################################'
echo "> Updating role to add datasciencepipelinesapplications/api subresource"
echo "> Role      : ${ROLE_NAME}"
echo "> Namespace : ${NAMESPACE}"
echo "> DSPA name : ${DSPA_NAME}"
echo "> Verbs     : ${VERBS}"
echo '################################################################################'

# Fetch the current role before patching (used for idempotency check and later validation)
if ! pre_role_json=$(kubectl get role "$ROLE_NAME" -n "$NAMESPACE" -o json); then
    echo "> [FAIL] Could not retrieve role '${ROLE_NAME}' in namespace '${NAMESPACE}'"
    exit 1
fi

# Check if the rule already exists to make the script idempotent
existing=$(echo "$pre_role_json" | jq -r \
    --arg dspa "$DSPA_NAME" \
    --argjson verbs "$verbs_json" \
    '[.rules[]
     | select(
         (.apiGroups | index("datasciencepipelinesapplications.opendatahub.io")) != null
         and (.resources | index("datasciencepipelinesapplications/api")) != null
         and (.resourceNames | index($dspa)) != null
         and ([$verbs[] | IN((.verbs)[])] | all)
     )] | length' 2>/dev/null)

if [[ "$existing" -ge 1 ]]; then
    echo "> [OK] Rule already exists in role '${ROLE_NAME}', no patch needed"
    exit 0
fi

patch=$(jq -n \
    --arg dspa "$DSPA_NAME" \
    --argjson verbs "$verbs_json" \
    '[{
        "op": "add",
        "path": "/rules/-",
        "value": {
            "apiGroups": ["datasciencepipelinesapplications.opendatahub.io"],
            "resources": ["datasciencepipelinesapplications/api"],
            "resourceNames": [$dspa],
            "verbs": $verbs
        }
    }]')

if ! kubectl patch role "$ROLE_NAME" -n "$NAMESPACE" --type=json -p "$patch"; then
    echo "> [FAIL] Failed to patch role '${ROLE_NAME}'"
    exit 1
fi

echo "> Validating role update..."

if ! role_json=$(kubectl get role "$ROLE_NAME" -n "$NAMESPACE" -o json); then
    echo "> [FAIL] Could not retrieve role '${ROLE_NAME}' for validation"
    exit 1
fi

# Verify the new rule exists with the correct apiGroup, resource, resourceName, and verbs
match=$(echo "$role_json" | jq -r \
    --arg dspa "$DSPA_NAME" \
    --argjson verbs "$verbs_json" \
    '[.rules[]
     | select(
         (.apiGroups | index("datasciencepipelinesapplications.opendatahub.io")) != null
         and (.resources | index("datasciencepipelinesapplications/api")) != null
         and (.resourceNames | index($dspa)) != null
         and ([$verbs[] | IN((.verbs)[])] | all)
     )] | length' 2>/dev/null)

if [[ "$match" -ge 1 ]]; then
    echo "> [OK]   Role '${ROLE_NAME}' patched and validated successfully"
    exit 0
else
    echo "> [FAIL] Patch appeared to succeed but validation failed: expected rule not found in role '${ROLE_NAME}'"
    exit 1
fi
