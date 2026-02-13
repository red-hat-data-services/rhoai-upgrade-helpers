#!/usr/bin/env bash

#
# TrustyAI Metrics Backup Script
#
# This script backs up all scheduled metrics from a TrustyAI service deployment.
# It exports the metrics configurations to a JSON file for later restoration.
#

set -euo pipefail

# Configuration
NAMESPACE="${TRUSTYAI_NAMESPACE:-}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
ROUTE_LABEL="${ROUTE_LABEL:-app=trustyai-service}"

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

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Backup TrustyAI scheduled metrics to a JSON file.

OPTIONS:
    -n, --namespace NAMESPACE    OpenShift namespace (required)
    -d, --backup-dir DIR         Backup directory (default: ./backups)
    -l, --route-label LABEL      Route label selector (default: app=trustyai-service)
    -t, --type TYPE              Metric type filter: all, fairness (default: all)
    -h, --help                   Show this help message

ENVIRONMENT VARIABLES:
    TRUSTYAI_NAMESPACE          Alternative to -n flag
    BACKUP_DIR                  Alternative to -d flag

EXAMPLES:
    $0 -n trustyai-ns
    $0 -n trustyai-ns -d /tmp/backups -t fairness
    TRUSTYAI_NAMESPACE=trustyai-ns $0

EOF
    exit 1
}

# Parse arguments
METRIC_TYPE="all"

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -d|--backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        -l|--route-label)
            ROUTE_LABEL="$2"
            shift 2
            ;;
        -t|--type)
            METRIC_TYPE="$2"
            shift 2
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

# Validate metric type
if [[ ! "${METRIC_TYPE}" =~ ^(all|fairness)$ ]]; then
    log_error "Invalid metric type: ${METRIC_TYPE}. Must be 'all' or 'fairness'."
    exit 1
fi

log_info "Starting TrustyAI metrics backup..."
log_info "Namespace: ${NAMESPACE}"
log_info "Backup directory: ${BACKUP_DIR}"
log_info "Metric type: ${METRIC_TYPE}"

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

# Check cluster connectivity
log_info "Checking cluster connectivity..."
if ! oc whoami &> /dev/null; then
    log_error "Not logged in to OpenShift cluster. Please run 'oc login' first."
    exit 1
fi

# Create backup directory
mkdir -p "${BACKUP_DIR}"
if [[ ! -d "${BACKUP_DIR}" ]]; then
    log_error "Failed to create backup directory: ${BACKUP_DIR}"
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

# Construct API URL
if [[ "${METRIC_TYPE}" == "fairness" ]]; then
    API_URL="https://${TRUSTYAI_ROUTE}/metrics/all/requests?type=fairness"
    BACKUP_TYPE_SUFFIX="-fairness"
else
    API_URL="https://${TRUSTYAI_ROUTE}/metrics/all/requests"
    BACKUP_TYPE_SUFFIX=""
fi

# Generate backup filename
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/trustyai-metrics${BACKUP_TYPE_SUFFIX}-${TIMESTAMP}.json"

# Fetch metrics
log_info "Fetching scheduled metrics from ${API_URL}..."
HTTP_CODE=$(curl -s -w "%{http_code}" -o "${BACKUP_FILE}" \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    "${API_URL}")

if [[ "${HTTP_CODE}" != "200" ]]; then
    log_error "Failed to fetch metrics. HTTP status: ${HTTP_CODE}"
    if [[ -f "${BACKUP_FILE}" ]]; then
        log_error "Response: $(cat ${BACKUP_FILE})"
        rm -f "${BACKUP_FILE}"
    fi
    exit 1
fi

# Validate JSON
log_info "Validating backup file..."
if ! jq empty "${BACKUP_FILE}" 2>/dev/null; then
    log_error "Invalid JSON in backup file"
    exit 1
fi

# Count metrics
METRIC_COUNT=$(jq '.requests | length' "${BACKUP_FILE}")
log_info "Successfully backed up ${METRIC_COUNT} scheduled metric(s)"

# Display summary
if [[ "${METRIC_COUNT}" -gt 0 ]]; then
    log_info "Backup summary:"
    jq -r '.requests[] | "  - \(.request.metricName) for model: \(.request.modelId) (ID: \(.id))"' "${BACKUP_FILE}"
fi

# Save metadata
METADATA_FILE="${BACKUP_DIR}/trustyai-metrics${BACKUP_TYPE_SUFFIX}-${TIMESTAMP}.metadata.json"
cat > "${METADATA_FILE}" << EOF
{
  "timestamp": "${TIMESTAMP}",
  "namespace": "${NAMESPACE}",
  "route": "${TRUSTYAI_ROUTE}",
  "metricType": "${METRIC_TYPE}",
  "metricCount": ${METRIC_COUNT},
  "backupFile": "$(basename ${BACKUP_FILE})"
}
EOF

log_info "Backup completed successfully!"
log_info "Backup file: ${BACKUP_FILE}"
log_info "Metadata file: ${METADATA_FILE}"

ln -sf "$(basename ${BACKUP_FILE})" "${BACKUP_DIR}/trustyai-metrics-latest.json"
log_info "Latest backup symlink: ${BACKUP_DIR}/trustyai-metrics-latest.json"

exit 0
