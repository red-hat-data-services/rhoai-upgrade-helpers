#!/usr/bin/env bash

set -euo pipefail

# This script is used to patch the GuardrailsOrchestrator deployment when upgrading from RHOAI 2.5 to 3.3

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [ $# -lt 1 ]; then
    echo -e "${RED}Usage: $0 <namespace>${NC}"
    exit 1
fi

NAMESPACE="${1}"
FAILED_DEPLOYMENTS=()
PATCHED_COUNT=0

echo ""
# Check if the user is logged in
if ! oc whoami &>/dev/null; then
    echo -e "${RED}ERROR: You are not logged in to the cluster${NC}"
    exit 1
fi

# Check if the namespace exists
if ! oc get namespace "${NAMESPACE}" &>/dev/null; then
    echo -e "${RED}ERROR: Namespace ${CYAN}${NAMESPACE}${RED} does not exist${NC}"
    exit 1
fi

# Check if GuardrailsOrchestrator CRs exist in namespace
echo -e "Checking for GuardrailsOrchestrator CRs in namespace ${CYAN}${NAMESPACE}${NC}"
GORCH_CR_NAMES=$(oc get guardrailsorchestrator -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
if [ -z "${GORCH_CR_NAMES}" ]; then
    echo -e "${RED}No GuardrailsOrchestrator CRs found in namespace ${CYAN}${NAMESPACE}${NC}"
    exit 1
fi

# Convert space-separated names to array
read -ra GORCH_CR_ARRAY <<< "${GORCH_CR_NAMES}"
echo ""
echo -e "Found ${GREEN}${#GORCH_CR_ARRAY[@]}${NC} GuardrailsOrchestrator CR(s) in namespace ${CYAN}${NAMESPACE}${NC}: ${BLUE}${GORCH_CR_NAMES}${NC}"

# Function to patch a single deployment
patch_deployment() {
    local deployment_name="$1"

    echo ""
    # Verify deployment exists
    if ! oc get deployment -n "${NAMESPACE}" "${deployment_name}" &>/dev/null; then
        echo -e "${YELLOW}WARNING: Deployment ${CYAN}${deployment_name}${YELLOW} not found in namespace ${CYAN}${NAMESPACE}${YELLOW}, skipping...${NC}"
        return 1
    fi

    # Patch the deployment to add the readinessProbe (port 8034, path /health, scheme HTTP)
    echo -e "Patching deployment ${CYAN}${deployment_name}${NC} in namespace ${CYAN}${NAMESPACE}${NC}"
    if ! oc patch deployment "${deployment_name}" -n "${NAMESPACE}" --type='strategic' -p='
spec:
  template:
    spec:
      containers:
      - name: guardrails-orchestrator
        readinessProbe:
          httpGet:
            path: /health
            port: 8034
            scheme: HTTP
          initialDelaySeconds: 10
          timeoutSeconds: 10
          periodSeconds: 20
          successThreshold: 1
          failureThreshold: 3
'; then
        echo -e "${RED}ERROR: Failed to patch deployment ${CYAN}${deployment_name}${NC}"
        return 1
    fi

    # Wait for rollout to complete
    echo ""
    echo -e "Waiting for rollout to complete..."
    if ! oc rollout status deployment "${deployment_name}" -n "${NAMESPACE}" --timeout=120s; then
        echo -e "${RED}ERROR: Deployment rollout failed for ${CYAN}${deployment_name}${NC}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}Successfully patched deployment ${CYAN}${deployment_name}${NC}"
    return 0
}

# Loop through all GuardrailsOrchestrator CRs
for CR_NAME in "${GORCH_CR_ARRAY[@]}"; do
    if patch_deployment "${CR_NAME}"; then
        ((PATCHED_COUNT++))
    else
        FAILED_DEPLOYMENTS+=("${CR_NAME}")
    fi
done

echo ""
echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD}GuardrailsOrchestrator Deployment Patch Summary${NC}"
echo -e "${BOLD}==========================================${NC}"
echo -e "Total GuardrailsOrchestrator CRs found: ${BLUE}${#GORCH_CR_ARRAY[@]}${NC}"
echo -e "Successfully patched: ${GREEN}${PATCHED_COUNT}${NC}"
echo -e "Failed: ${RED}${#FAILED_DEPLOYMENTS[@]}${NC}"

if [ ${#FAILED_DEPLOYMENTS[@]} -gt 0 ]; then
    echo -e "${RED}Failed deployments: ${CYAN}${FAILED_DEPLOYMENTS[*]}${NC}"
    exit 1
fi

echo -e "${GREEN}All guardrails deployments patched successfully!${NC}"
