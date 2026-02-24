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

usage() {
    echo -e "Usage: $0 ${BOLD}-n|--namespace <namespace>${NC} ${BOLD}-g|--gorch-name <name>${NC} [${BOLD}--check${NC}|${BOLD}--fix${NC}] [${BOLD}--dry-run${NC}]"
    echo ""
    echo "  -n, --namespace <ns>   Target namespace (required)"
    echo "  -g, --gorch-name <name> GuardrailsOrchestrator CR/deployment name (required)"
    echo "  --check                Show current status only: OK / NEEDS PATCH / MISSING (default)"
    echo "  --fix                  Apply readinessProbe patch to deployment"
    echo "  --dry-run              Show what would be patched without applying (runs fix path in preview)"
    exit 1
}

NAMESPACE=""
GORCH_NAME=""
MODE="check"
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--namespace)
            if [ -n "${2:-}" ]; then
                NAMESPACE="$2"
                shift 2
            else
                echo -e "${RED}ERROR: --namespace requires a value${NC}"
                usage
            fi
            ;;
        --namespace=*)
            NAMESPACE="${1#*=}"
            shift
            ;;
        -g|--gorch-name)
            if [ -n "${2:-}" ]; then
                GORCH_NAME="$2"
                shift 2
            else
                echo -e "${RED}ERROR: --gorch-name requires a value${NC}"
                usage
            fi
            ;;
        --gorch-name=*)
            GORCH_NAME="${1#*=}"
            shift
            ;;
        --check)
            MODE="check"
            shift
            ;;
        --fix)
            MODE="fix"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}ERROR: Unknown argument: $1${NC}"
            usage
            ;;
    esac
done

if [ -z "${NAMESPACE}" ]; then
    echo -e "${RED}ERROR: Namespace is required${NC}"
    usage
fi
if [ -z "${GORCH_NAME}" ]; then
    echo -e "${RED}ERROR: --gorch-name is required${NC}"
    usage
fi

FAILED_DEPLOYMENTS=()

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

# Verify the specified GuardrailsOrchestrator CR exists in namespace
echo -e " [INFO] Checking GuardrailsOrchestrator ${CYAN}${GORCH_NAME}${NC} in namespace ${CYAN}${NAMESPACE}${NC}"
if ! oc get guardrailsorchestrator -n "${NAMESPACE}" "${GORCH_NAME}" &>/dev/null; then
    echo -e "${RED}ERROR: GuardrailsOrchestrator ${CYAN}${GORCH_NAME}${RED} not found in namespace ${CYAN}${NAMESPACE}${NC}"
    exit 1
fi

# Check if deployment has the expected readinessProbe (port 8034, path /health) on the container matching GORCH_NAME
needs_patch() {
    local deployment_name="$1"
    local probe_path
    probe_path=$(oc get deployment -n "${NAMESPACE}" "${deployment_name}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="'"${deployment_name}"'")].readinessProbe.httpGet.path}' 2>/dev/null || true)
    local probe_port
    probe_port=$(oc get deployment -n "${NAMESPACE}" "${deployment_name}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="'"${deployment_name}"'")].readinessProbe.httpGet.port}' 2>/dev/null || true)
    [ "${probe_path}" != "/health" ] || [ "${probe_port}" != "8034" ]
}


check_deployment() {
    local deployment_name="$1"
    echo ""
    if ! oc get deployment -n "${NAMESPACE}" "${deployment_name}" &>/dev/null; then
        echo -e "  ${RED}MISSING${NC}  deployment ${CYAN}${deployment_name}${NC}"
        return 1
    fi
    if needs_patch "${deployment_name}"; then
        echo -e "  ${YELLOW}[CHECK] ${RED}NEEDS PATCH${NC}  deployment ${CYAN}${deployment_name}${NC}"
        return 0
    else
        echo -e " ${YELLOW}[CHECK] ${GREEN}OK${NC}  deployment ${CYAN}${deployment_name}${NC} (readinessProbe already set)"
        return 0
    fi
}

# Function to patch a single deployment
patch_deployment() {
    local deployment_name="$1"

    echo ""
    # Verify deployment exists
    if ! oc get deployment -n "${NAMESPACE}" "${deployment_name}" &>/dev/null; then
        echo -e "${YELLOW}WARNING: Deployment ${CYAN}${deployment_name}${YELLOW} not found in namespace ${CYAN}${NAMESPACE}${YELLOW}, skipping...${NC}"
        return 1
    fi

    if [ "${DRY_RUN}" = true ]; then
        if needs_patch "${deployment_name}"; then
            echo -e "${CYAN}[DRY-RUN]${NC} Would patch deployment ${CYAN}${deployment_name}${NC} in namespace ${CYAN}${NAMESPACE}${NC} (add readinessProbe: port 8034, path /health)"
        else
            echo -e "${CYAN}[DRY-RUN]${NC} Deployment ${CYAN}${deployment_name}${NC} already has expected readinessProbe, skip"
        fi
        return 0
    fi

    # Skip patch and rollout if readinessProbe is already set
    if ! needs_patch "${deployment_name}"; then
        echo ""
        echo -e "[INFO] Deployment ${CYAN}${deployment_name}${NC} already has expected readinessProbe, skip"
        return 2
    fi

    # Patch the container matching deployment name (GORCH_NAME) to add readinessProbe (port 8034, path /health)
    echo -e " [INFO] Patching deployment ${CYAN}${deployment_name}${NC} in namespace ${CYAN}${NAMESPACE}${NC}"
    if ! oc patch deployment "${deployment_name}" -n "${NAMESPACE}" --type='strategic' -p "
spec:
  template:
    spec:
      containers:
      - name: ${deployment_name}
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
"; then
        echo -e "${RED}ERROR: Failed to patch deployment ${CYAN}${deployment_name}${NC}"
        return 1
    fi

    # Wait for rollout to complete
    echo ""
    echo -e " [INFO] Waiting for rollout to complete..."
    echo -e ""
    if ! oc rollout status deployment "${deployment_name}" -n "${NAMESPACE}" --timeout=120s; then
        echo -e "${RED}ERROR: Deployment rollout failed for ${CYAN}${deployment_name}${NC}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}Successfully patched deployment ${CYAN}${deployment_name}${NC}"
    return 0
}

# --check: show current status only (OK / NEEDS PATCH / MISSING). --dry-run: show what would be patched, no changes.
if [ "${MODE}" = "check" ] && [ "${DRY_RUN}" != true ]; then
    echo ""
    check_deployment "${GORCH_NAME}" || true
    echo ""
    echo -e "${GREEN}Check complete.${NC}"
    exit 0
fi

patch_deployment "${GORCH_NAME}"
patch_ret=$?
if [ "$patch_ret" -eq 0 ]; then
    : # success
elif [ "$patch_ret" -eq 2 ]; then
    : # skipped (readinessProbe already present)
else
    FAILED_DEPLOYMENTS+=("${GORCH_NAME}")
fi

echo ""
echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD}GuardrailsOrchestrator Deployment Patch Summary${NC}"
echo -e "${BOLD}=========================================${NC}"

if [ "${DRY_RUN}" = true ]; then
    echo -e "${CYAN}(DRY-RUN: no changes were made)${NC}"
elif [ ${#FAILED_DEPLOYMENTS[@]} -gt 0 ]; then
    echo -e "${RED}FAIL: ${CYAN}${FAILED_DEPLOYMENTS[*]}${NC}"
    exit 1
else
    echo -e "${GREEN}OK: ${CYAN}${GORCH_NAME}${GREEN} patched successfully!${NC}"
fi
