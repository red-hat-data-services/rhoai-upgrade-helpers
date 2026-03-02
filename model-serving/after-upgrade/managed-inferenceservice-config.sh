#!/usr/bin/env bash
# Set inferenceservice-config annotation to managed and restart KServe controller.

set -e

CONFIGMAP_NAME="inferenceservice-config"

usage() {
  echo "Usage: $0 -n|--namespace <namespace>"
  exit 1
}

NAMESPACE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$NAMESPACE" ]] || usage

# Show current annotation and intent
CONFIGMAP_JSON=$(oc get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o json 2>/dev/null) || true
CURRENT_VALUE="not-set"
if [[ -n "$CONFIGMAP_JSON" ]] && command -v jq &>/dev/null; then
  CURRENT_VALUE=$(echo "$CONFIGMAP_JSON" | jq -r '.metadata.annotations["opendatahub.io/managed"] // "not-set"')
fi
echo "Annotation 'opendatahub.io/managed' is '$CURRENT_VALUE', will set to 'true'"

oc annotate configmap "$CONFIGMAP_NAME" opendatahub.io/managed='true' --overwrite -n "$NAMESPACE"
echo "Added annotation: opendatahub.io/managed=true"

echo "Restarting kserve-controller-manager deployment..."
oc rollout restart deployment kserve-controller-manager -n "$NAMESPACE"

echo "Waiting for rollout to complete..."
oc rollout status deployment kserve-controller-manager -n "$NAMESPACE" --timeout=120s

echo "Controller restarted successfully"
echo "Done"
