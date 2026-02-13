#!/usr/bin/env bash

#
# TrustyAI Metrics Restore Script
#
# This script restores scheduled metrics to a TrustyAI service deployment
# from a previously created backup file.
#

set -euo pipefail

# Configuration
NAMESPACE="${TRUSTYAI_NAMESPACE:-}"
BACKUP_FILE=""
ROUTE_LABEL="${ROUTE_LABEL:-app=trustyai-service}"
DRY_RUN=false
SKIP_EXISTING=false

# Counters
TOTAL_METRICS=0
SUCCESSFUL=0
FAILED=0
SKIPPED=0

# Functions
log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_debug() {
    echo "[DEBUG] $1"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Restore TrustyAI scheduled metrics from a backup file.

OPTIONS:
    -n, --namespace NAMESPACE    OpenShift namespace (required)
    -f, --file FILE              Backup file to restore from (required)
    -l, --route-label LABEL      Route label selector (default: app=trustyai-service)
    -d, --dry-run                Show what would be restored without making changes
    -s, --skip-existing          Skip metrics that already exist (check by model ID and metric type)
    -h, --help                   Show this help message

ENVIRONMENT VARIABLES:
    TRUSTYAI_NAMESPACE          Alternative to -n flag

EXAMPLES:
    $0 -n trustyai-ns -f backups/trustyai-metrics-20240101-120000.json
    $0 -n trustyai-ns -f backups/trustyai-metrics-latest.json --dry-run
    $0 -n trustyai-ns -f backup.json --skip-existing

EOF
    exit 1
}

# Get endpoint for metric type
get_endpoint() {
    local metric_name=$1
    local route=$2

    case ${metric_name} in
        SPD)
            echo "https://${route}/metrics/group/fairness/spd/request"
            ;;
        DIR)
            echo "https://${route}/metrics/group/fairness/dir/request"
            ;;
        meanshift)
            echo "https://${route}/metrics/drift/meanshift/request"
            ;;
        kstest)
            echo "https://${route}/metrics/drift/kstest/request"
            ;;
        approxkstest)
            echo "https://${route}/metrics/drift/approxkstest/request"
            ;;
        fouriermmd)
            echo "https://${route}/metrics/drift/fouriermmd/request"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Check if metric already exists
check_metric_exists() {
    local model_id=$1
    local metric_name=$2
    local existing_metrics=$3

    echo "${existing_metrics}" | jq -e --arg model "${model_id}" --arg metric "${metric_name}" \
        '.requests[] | select(.request.modelId == $model and .request.metricName == $metric)' > /dev/null 2>&1
    return $?
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -f|--file)
            BACKUP_FILE="$2"
            shift 2
            ;;
        -l|--route-label)
            ROUTE_LABEL="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -s|--skip-existing)
            SKIP_EXISTING=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "${NAMESPACE}" ]]; then
    log_error "Namespace is required. Use -n flag or set TRUSTYAI_NAMESPACE environment variable."
    usage
fi

if [[ -z "${BACKUP_FILE}" ]]; then
    log_error "Backup file is required. Use -f flag."
    usage
fi

if [[ ! -f "${BACKUP_FILE}" ]]; then
    log_error "Backup file not found: ${BACKUP_FILE}"
    exit 1
fi

log_info "Starting TrustyAI metrics restore..."
log_info "Namespace: ${NAMESPACE}"
log_info "Backup file: ${BACKUP_FILE}"
if [[ "${DRY_RUN}" == true ]]; then
    log_warn "DRY RUN MODE - No changes will be made"
fi
if [[ "${SKIP_EXISTING}" == true ]]; then
    log_info "Skip existing metrics: enabled"
fi

# Check prerequisites
if ! command -v oc &> /dev/null; then
    log_error "oc CLI not found. Please install the OpenShift CLI."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "jq not found. Please install jq for JSON processing."
    exit 1
fi

if ! command -v curl &> /dev/null; then
    log_error "curl not found. Please install curl."
    exit 1
fi

# Validate backup file JSON
log_info "Validating backup file..."
if ! jq empty "${BACKUP_FILE}" 2>/dev/null; then
    log_error "Invalid JSON in backup file"
    exit 1
fi

# Check if backup file has the expected structure
if ! jq -e '.requests' "${BACKUP_FILE}" > /dev/null 2>&1; then
    log_error "Backup file does not have expected structure (missing .requests array)"
    exit 1
fi

TOTAL_METRICS=$(jq '.requests | length' "${BACKUP_FILE}")
log_info "Found ${TOTAL_METRICS} metric(s) to restore"

if [[ "${TOTAL_METRICS}" -eq 0 ]]; then
    log_warn "No metrics found in backup file. Nothing to restore."
    exit 0
fi

# Check cluster connectivity
log_info "Checking cluster connectivity..."
if ! oc whoami &> /dev/null; then
    log_error "Not logged in to OpenShift cluster. Please run 'oc login' first."
    exit 1
fi

# Get TrustyAI route
log_info "Fetching TrustyAI service route..."
TRUSTYAI_ROUTE=$(oc get route -n "${NAMESPACE}" -l "${ROUTE_LABEL}" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

if [[ -z "${TRUSTYAI_ROUTE}" ]]; then
    log_error "Could not find TrustyAI route in namespace ${NAMESPACE} with label ${ROUTE_LABEL}"
    log_error "Please check that the TrustyAI service is deployed and the route exists."
    exit 1
fi

log_info "TrustyAI route: ${TRUSTYAI_ROUTE}"

# Get authentication token
log_info "Retrieving authentication token..."
AUTH_TOKEN=$(oc whoami -t 2>/dev/null || echo "")

if [[ -z "${AUTH_TOKEN}" ]]; then
    log_error "Could not retrieve authentication token"
    log_error "Please ensure you are logged in to the cluster"
    exit 1
fi

# Check service health
log_info "Checking TrustyAI service health..."
HEALTH_CHECK=$(curl -s -H "Authorization: Bearer ${AUTH_TOKEN}" \
    "https://${TRUSTYAI_ROUTE}/q/health/ready" || echo '{"status":"DOWN"}')
HEALTH_STATUS=$(echo "${HEALTH_CHECK}" | jq -r '.status // "UNKNOWN"')

if [[ "${HEALTH_STATUS}" != "UP" ]]; then
    log_warn "TrustyAI service health check returned: ${HEALTH_STATUS}"
    log_warn "Service may not be ready. Restoration might fail."
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Restoration cancelled."
        exit 0
    fi
fi

# Get existing metrics if skip-existing is enabled
EXISTING_METRICS=""
if [[ "${SKIP_EXISTING}" == true ]]; then
    log_info "Fetching existing metrics..."
    EXISTING_METRICS=$(curl -s -H "Authorization: Bearer ${AUTH_TOKEN}" \
        "https://${TRUSTYAI_ROUTE}/metrics/all/requests")
    EXISTING_COUNT=$(echo "${EXISTING_METRICS}" | jq '.requests | length')
    log_info "Found ${EXISTING_COUNT} existing metric(s)"
fi

# Process each metric
log_info "Processing metrics..."
echo ""

jq -c '.requests[]' "${BACKUP_FILE}" | while read -r metric; do
    METRIC_NAME=$(echo "${metric}" | jq -r '.request.metricName')
    MODEL_ID=$(echo "${metric}" | jq -r '.request.modelId')
    OLD_ID=$(echo "${metric}" | jq -r '.id')
    REQUEST_PAYLOAD=$(echo "${metric}" | jq -c '.request')

    log_info "Processing: ${METRIC_NAME} for model ${MODEL_ID} (original ID: ${OLD_ID})"

    # Check if metric exists (if skip-existing is enabled)
    if [[ "${SKIP_EXISTING}" == true ]] && [[ -n "${EXISTING_METRICS}" ]]; then
        if check_metric_exists "${MODEL_ID}" "${METRIC_NAME}" "${EXISTING_METRICS}"; then
            log_warn "  Metric already exists, skipping..."
            ((SKIPPED++)) || true
            continue
        fi
    fi

    # Get appropriate endpoint
    ENDPOINT=$(get_endpoint "${METRIC_NAME}" "${TRUSTYAI_ROUTE}")

    if [[ -z "${ENDPOINT}" ]]; then
        log_error "  Unknown metric type: ${METRIC_NAME}, skipping..."
        ((FAILED++)) || true
        continue
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "  [DRY RUN] Would POST to: ${ENDPOINT}"
        log_debug "  [DRY RUN] Payload: ${REQUEST_PAYLOAD}"
        ((SUCCESSFUL++)) || true
        continue
    fi

    # Make the request
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${ENDPOINT}" \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${REQUEST_PAYLOAD}")

    HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
    RESPONSE_BODY=$(echo "${RESPONSE}" | head -n-1)

    if [[ "${HTTP_CODE}" == "200" ]]; then
        NEW_ID=$(echo "${RESPONSE_BODY}" | jq -r '.requestId // empty')
        if [[ -n "${NEW_ID}" ]]; then
            log_info "  ✓ Successfully scheduled with new ID: ${NEW_ID}"
            ((SUCCESSFUL++)) || true
        else
            log_warn "  Metric scheduled but no request ID returned"
            log_debug "  Response: ${RESPONSE_BODY}"
            ((SUCCESSFUL++)) || true
        fi
    else
        log_error "  ✗ Failed with HTTP ${HTTP_CODE}"
        log_error "  Response: ${RESPONSE_BODY}"
        ((FAILED++)) || true
    fi

    # Small delay to avoid overwhelming the service
    sleep 0.5
done

# Summary
echo ""
log_info "=========================================="
log_info "Restoration Summary"
log_info "=========================================="
log_info "Total metrics in backup: ${TOTAL_METRICS}"
log_info "Successfully restored:   ${SUCCESSFUL}"
log_info "Failed:                  ${FAILED}"
log_info "Skipped:                 ${SKIPPED}"
log_info "=========================================="

if [[ "${DRY_RUN}" == true ]]; then
    log_info "DRY RUN completed - no changes were made"
fi

# Verify restoration
if [[ "${DRY_RUN}" == false ]] && [[ "${SUCCESSFUL}" -gt 0 ]]; then
    echo ""
    log_info "Verifying restoration..."
    CURRENT_METRICS=$(curl -s -H "Authorization: Bearer ${AUTH_TOKEN}" \
        "https://${TRUSTYAI_ROUTE}/metrics/all/requests")
    CURRENT_COUNT=$(echo "${CURRENT_METRICS}" | jq '.requests | length')
    log_info "Current scheduled metrics: ${CURRENT_COUNT}"

    echo ""
    log_info "Current metrics:"
    echo "${CURRENT_METRICS}" | jq -r '.requests[] | "  - \(.request.metricName) for model: \(.request.modelId) (ID: \(.id))"'
fi

# Exit with appropriate code
if [[ "${FAILED}" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
