#!/usr/bin/env bash

#
# TrustyAI Data Storage Restore Script
#
# Restores TrustyAI data storage (PVC or database) from a backup
# created by backup-data.sh.
#
# PVC:      rsyncs directly into the running TrustyAI service pod
#           (no temporary pod, no image pull — works on disconnected clusters)
# DATABASE: restores a SQL dump via the existing database pod
#

set -euo pipefail

# Configuration
NAMESPACE="${TRUSTYAI_NAMESPACE:-}"
BACKUP_PATH=""
METADATA_FILE=""
TAS_NAME=""
DRY_RUN=false

# Functions
log_info()  { echo "[INFO] $1"; }
log_warn()  { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1" >&2; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Restore TrustyAI data storage (PVC or database) from a backup.

The script infers the storage type from the backup path:
  - Directory  → PVC restore  (rsyncs into the running TrustyAI pod)
  - .sql file  → DB restore   (pipes dump into the MariaDB pod)

No temporary pods or external images are required.

OPTIONS:
    -n, --namespace NAMESPACE    OpenShift namespace (required)
    -f, --file PATH              Backup path: directory (PVC) or .sql file (DB) (required)
    -s, --service-name NAME      TrustyAIService name (default: auto-detect)
    -m, --metadata FILE          Metadata JSON file (default: auto-detect from backup path)
    -d, --dry-run                Show what would be restored without making changes
    -h, --help                   Show this help message

ENVIRONMENT VARIABLES:
    TRUSTYAI_NAMESPACE          Alternative to -n flag

EXAMPLES:
    $0 -n my-namespace -f backups/trustyai-data-my-namespace-20260101-120000/
    $0 -n my-namespace -f backups/trustyai-db-my-namespace-20260101-120000.sql
    $0 -n my-namespace -f backups/trustyai-db-my-namespace-20260101-120000.sql --dry-run

EOF
    exit 1
}

# ──────────────────────────────────────────────
# Shared helpers (same as backup-data.sh)
# ──────────────────────────────────────────────
find_pod_by_labels() {
    local ns="$1"; shift
    for label in "$@"; do
        local pod
        pod=$(oc get pods -n "${ns}" -l "${label}" \
            --field-selector=status.phase=Running \
            --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null \
            | head -1 || echo "")
        if [[ -n "${pod}" ]]; then
            echo "${pod}"
            return 0
        fi
    done
    echo ""
}

find_pod_by_name() {
    local ns="$1" pattern="$2"
    oc get pods -n "${ns}" --field-selector=status.phase=Running \
        --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null \
        | grep -i "${pattern}" | head -1 || echo ""
}

try_secret_keys() {
    local ns="$1" secret="$2"; shift 2
    for key in "$@"; do
        local val
        val=$(oc get secret "${secret}" -n "${ns}" \
            -o jsonpath="{.data.${key}}" 2>/dev/null || echo "")
        if [[ -n "${val}" ]]; then
            echo "${val}" | base64 -d 2>/dev/null
            return 0
        fi
    done
    echo ""
}

detect_client_cmd() {
    local ns="$1" pod="$2"
    for cmd in mariadb mysql; do
        if oc exec -n "${ns}" -c mariadb "${pod}" -- which "${cmd}" &>/dev/null; then
            echo "${cmd}"
            return 0
        fi
    done
    echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -f|--file) BACKUP_PATH="$2"; shift 2 ;;
        -s|--service-name) TAS_NAME="$2"; shift 2 ;;
        -m|--metadata) METADATA_FILE="$2"; shift 2 ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Validate
if [[ -z "${NAMESPACE}" ]]; then
    log_error "Namespace is required. Use -n flag or set TRUSTYAI_NAMESPACE environment variable."
    usage
fi

if [[ -z "${BACKUP_PATH}" ]]; then
    log_error "Backup path is required. Use -f flag."
    usage
fi

if [[ ! -e "${BACKUP_PATH}" ]]; then
    log_error "Backup path not found: ${BACKUP_PATH}"
    exit 1
fi

for tool in oc jq; do
    if ! command -v "${tool}" &>/dev/null; then
        log_error "${tool} not found. Please install it."
        exit 1
    fi
done

log_info "Checking cluster connectivity..."
if ! oc whoami &>/dev/null; then
    log_error "Not logged in to OpenShift cluster. Please run 'oc login' first."
    exit 1
fi

# Determine storage type from the backup directory
# The backup path should be a directory containing metadata.json and either
# data/ (PVC) or dump.sql (DATABASE).
STORAGE_FORMAT=""

if [[ ! -d "${BACKUP_PATH}" ]]; then
    log_error "Backup path must be a directory: ${BACKUP_PATH}"
    log_error "Expected a backup directory created by backup-data.sh"
    exit 1
fi

# Look for metadata.json inside the backup directory
if [[ -z "${METADATA_FILE}" ]]; then
    local_meta="${BACKUP_PATH%/}/metadata.json"
    if [[ -f "${local_meta}" ]]; then
        METADATA_FILE="${local_meta}"
    fi
fi

if [[ -n "${METADATA_FILE}" ]]; then
    log_info "Found metadata file: ${METADATA_FILE}"
    STORAGE_FORMAT=$(jq -r '.storageFormat' "${METADATA_FILE}")
elif [[ -d "${BACKUP_PATH%/}/data" ]]; then
    STORAGE_FORMAT="PVC"
elif [[ -f "${BACKUP_PATH%/}/dump.sql" ]]; then
    STORAGE_FORMAT="DATABASE"
else
    log_error "Cannot determine backup type from ${BACKUP_PATH}"
    log_error "Expected data/ subdirectory (PVC) or dump.sql (database) inside"
    exit 1
fi

# Auto-detect TrustyAIService name
if [[ -z "${TAS_NAME}" ]]; then
    # Try metadata first
    if [[ -n "${METADATA_FILE}" ]]; then
        TAS_NAME=$(jq -r '.trustyaiService // empty' "${METADATA_FILE}" 2>/dev/null || echo "")
    fi
    # Fall back to cluster
    if [[ -z "${TAS_NAME}" ]]; then
        TAS_NAME=$(oc get trustyaiservice -n "${NAMESPACE}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    if [[ -z "${TAS_NAME}" ]]; then
        log_error "No TrustyAIService found in namespace ${NAMESPACE}"
        exit 1
    fi
fi

log_info "Starting TrustyAI data restore..."
log_info "Namespace: ${NAMESPACE}"
log_info "TrustyAIService: ${TAS_NAME}"
log_info "Storage format: ${STORAGE_FORMAT}"
log_info "Backup path: ${BACKUP_PATH}"
if [[ "${DRY_RUN}" == true ]]; then
    log_warn "DRY RUN MODE - No changes will be made"
fi

# ──────────────────────────────────────────────
# PVC restore — rsync directly into the TrustyAI service pod
# ──────────────────────────────────────────────
restore_pvc() {
    log_info "Starting PVC restore..."

    local data_dir="${BACKUP_PATH%/}/data"

    if [[ ! -d "${data_dir}" ]]; then
        log_error "No data/ subdirectory found in backup: ${BACKUP_PATH}"
        exit 1
    fi

    local file_count
    file_count=$(find "${data_dir}" -type f | wc -l)

    if [[ "${file_count}" -eq 0 ]]; then
        log_warn "Backup directory is empty (0 files). Nothing to restore."
        exit 0
    fi

    log_info "Found ${file_count} file(s) to restore"

    # 1. Find the TrustyAI service pod
    local tas_pod
    tas_pod=$(find_pod_by_labels "${NAMESPACE}" \
        "app=${TAS_NAME}" \
        "app.kubernetes.io/name=${TAS_NAME}" \
        "app.kubernetes.io/part-of=trustyai")

    if [[ -z "${tas_pod}" ]]; then
        tas_pod=$(find_pod_by_name "${NAMESPACE}" "${TAS_NAME}")
    fi

    if [[ -z "${tas_pod}" ]]; then
        log_error "No running TrustyAI service pod found in namespace ${NAMESPACE}"
        log_info "Pods in namespace:"
        oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null || echo "  (none)"
        exit 1
    fi

    log_info "TrustyAI pod: ${tas_pod}"

    # 2. Find the PVC mount path (same logic as backup)
    local mount_path=""

    # Try metadata first
    if [[ -n "${METADATA_FILE}" ]]; then
        mount_path=$(jq -r '.mountPath // empty' "${METADATA_FILE}" 2>/dev/null || echo "")
    fi

    # Try operator convention: volume named "volume"
    if [[ -z "${mount_path}" ]]; then
        mount_path=$(oc get pod "${tas_pod}" -n "${NAMESPACE}" -o json 2>/dev/null \
            | jq -r '
                .spec.containers[0].volumeMounts[]
                | select(.name == "volume")
                | .mountPath' 2>/dev/null || echo "")
    fi

    # Fallback: find PVC mount matching TAS name
    if [[ -z "${mount_path}" ]]; then
        mount_path=$(oc get pod "${tas_pod}" -n "${NAMESPACE}" -o json 2>/dev/null \
            | jq -r --arg tas "${TAS_NAME}" '
                .spec.volumes[] as $v
                | select($v.persistentVolumeClaim != null)
                | select($v.persistentVolumeClaim.claimName | test($tas; "i"))
                | $v.name as $vn
                | input_line_number
                | . as $dummy
                | null
            ' 2>/dev/null || echo "")

        # Simpler approach: just get volume names with PVCs, match to mounts
        if [[ -z "${mount_path}" ]]; then
            local pvc_vol_name
            pvc_vol_name=$(oc get pod "${tas_pod}" -n "${NAMESPACE}" -o json 2>/dev/null \
                | jq -r --arg tas "${TAS_NAME}" '
                    .spec.volumes[]
                    | select(.persistentVolumeClaim != null)
                    | select(.persistentVolumeClaim.claimName | test($tas; "i"))
                    | .name' 2>/dev/null | head -1 || echo "")

            if [[ -n "${pvc_vol_name}" ]]; then
                mount_path=$(oc get pod "${tas_pod}" -n "${NAMESPACE}" -o json 2>/dev/null \
                    | jq -r --arg vn "${pvc_vol_name}" '
                        .spec.containers[0].volumeMounts[]
                        | select(.name == $vn)
                        | .mountPath' 2>/dev/null || echo "")
            fi
        fi
    fi

    # Last resort: CR spec
    if [[ -z "${mount_path}" ]]; then
        mount_path=$(oc get trustyaiservice "${TAS_NAME}" -n "${NAMESPACE}" \
            -o jsonpath='{.spec.storage.folder}' 2>/dev/null || echo "")
    fi

    if [[ -z "${mount_path}" ]]; then
        log_error "Could not determine PVC mount path from pod or CR"
        log_info "Pod volume mounts:"
        oc get pod "${tas_pod}" -n "${NAMESPACE}" \
            -o jsonpath='{range .spec.containers[0].volumeMounts[*]}{.name}: {.mountPath}{"\n"}{end}' 2>/dev/null
        exit 1
    fi

    log_info "Mount path: ${mount_path}"

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would rsync ${file_count} file(s) from ${data_dir}/ to ${tas_pod}:${mount_path}/"
        log_info "[DRY RUN] Files:"
        find "${data_dir}" -type f | head -20
        local total
        total=$(find "${data_dir}" -type f | wc -l)
        if [[ "${total}" -gt 20 ]]; then
            log_info "[DRY RUN] ... and $((total - 20)) more"
        fi
        return
    fi

    # 3. Rsync data into the pod
    # The operator hardcodes the container name as "trustyai-service".
    # Specifying it explicitly avoids ambiguity with the kube-rbac-proxy sidecar.
    log_info "Copying data into ${tas_pod}:${mount_path}/ ..."
    oc rsync -n "${NAMESPACE}" -c trustyai-service "${data_dir}/" "${tas_pod}:${mount_path}/"

    log_info "PVC restore completed successfully!"
    log_warn "You may need to restart the TrustyAI pod for it to pick up restored data:"
    log_warn "  oc delete pod ${tas_pod} -n ${NAMESPACE}"
}

# ──────────────────────────────────────────────
# Database restore — pipe SQL dump into the MariaDB pod
# ──────────────────────────────────────────────
restore_database() {
    log_info "Starting database restore..."

    local dump_file="${BACKUP_PATH%/}/dump.sql"

    if [[ ! -f "${dump_file}" ]]; then
        log_error "No dump.sql found in backup: ${BACKUP_PATH}"
        exit 1
    fi

    local line_count
    line_count=$(wc -l < "${dump_file}")

    if [[ "${line_count}" -le 1 ]]; then
        log_error "SQL dump appears empty (${line_count} lines). Cannot restore."
        exit 1
    fi

    log_info "SQL dump: ${line_count} lines"

    # 1. Find the database credentials secret (same logic as backup)
    local db_secret=""

    if [[ -n "${METADATA_FILE}" ]]; then
        db_secret=$(jq -r '.credentialsSecret // .mariadbSecret // empty' "${METADATA_FILE}" 2>/dev/null || echo "")
        # Verify secret still exists
        if [[ -n "${db_secret}" ]]; then
            if ! oc get secret "${db_secret}" -n "${NAMESPACE}" &>/dev/null; then
                log_warn "Secret from metadata (${db_secret}) not found, searching..."
                db_secret=""
            fi
        fi
    fi

    # Try the CR-specified secret name
    if [[ -z "${db_secret}" ]]; then
        db_secret=$(oc get trustyaiservice "${TAS_NAME}" -n "${NAMESPACE}" \
            -o jsonpath='{.spec.storage.databaseConfigurations}' 2>/dev/null || echo "")
        if [[ -n "${db_secret}" ]] && ! oc get secret "${db_secret}" -n "${NAMESPACE}" &>/dev/null; then
            log_warn "Secret '${db_secret}' from CR spec.storage.databaseConfigurations not found, searching..."
            db_secret=""
        fi
    fi

    # Try operator default convention
    if [[ -z "${db_secret}" ]] && oc get secret "${TAS_NAME}-db-credentials" -n "${NAMESPACE}" &>/dev/null; then
        db_secret="${TAS_NAME}-db-credentials"
    fi

    if [[ -z "${db_secret}" ]]; then
        db_secret=$(oc get secret -n "${NAMESPACE}" --no-headers \
            -o custom-columns='NAME:.metadata.name' 2>/dev/null \
            | grep -i 'db-credentials' | head -1 || echo "")
    fi

    if [[ -z "${db_secret}" ]]; then
        db_secret=$(oc get secret -n "${NAMESPACE}" --no-headers \
            -o custom-columns='NAME:.metadata.name' 2>/dev/null \
            | grep -i 'mariadb' | head -1 || echo "")
    fi

    if [[ -z "${db_secret}" ]]; then
        log_error "No database credentials secret found in namespace ${NAMESPACE}"
        exit 1
    fi

    log_info "Credentials secret: ${db_secret}"

    # 2. Extract credentials
    local db_user db_pass db_name

    db_user=$(try_secret_keys "${NAMESPACE}" "${db_secret}" \
        databaseUsername databaseUser database-username database-user \
        MYSQL_USER DB_USER user username)
    db_pass=$(try_secret_keys "${NAMESPACE}" "${db_secret}" \
        databasePassword database-password \
        MYSQL_PASSWORD DB_PASSWORD password)
    db_name=$(try_secret_keys "${NAMESPACE}" "${db_secret}" \
        databaseName database-name \
        MYSQL_DATABASE DB_NAME database)

    if [[ -z "${db_user}" || -z "${db_pass}" || -z "${db_name}" ]]; then
        log_error "Could not extract database credentials from secret ${db_secret}"
        log_info "Secret keys present:"
        oc get secret "${db_secret}" -n "${NAMESPACE}" \
            -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys[]' 2>/dev/null || echo "  (could not read)"
        exit 1
    fi

    log_info "Database: ${db_name} (user: ${db_user})"

    # 3. Find the MariaDB pod
    local mariadb_pod=""

    if [[ -n "${METADATA_FILE}" ]]; then
        mariadb_pod=$(jq -r '.mariadbPod // empty' "${METADATA_FILE}" 2>/dev/null || echo "")
        if [[ -n "${mariadb_pod}" ]]; then
            # Pod name may have changed after upgrade (new StatefulSet revision)
            if ! oc get pod "${mariadb_pod}" -n "${NAMESPACE}" &>/dev/null; then
                log_warn "MariaDB pod from metadata (${mariadb_pod}) no longer exists, searching..."
                mariadb_pod=""
            fi
        fi
    fi

    if [[ -z "${mariadb_pod}" ]]; then
        mariadb_pod=$(find_pod_by_name "${NAMESPACE}" "mariadb-${TAS_NAME}")
    fi
    if [[ -z "${mariadb_pod}" ]]; then
        mariadb_pod=$(find_pod_by_name "${NAMESPACE}" "mariadb")
    fi
    if [[ -z "${mariadb_pod}" ]]; then
        mariadb_pod=$(find_pod_by_name "${NAMESPACE}" "mysql")
    fi
    if [[ -z "${mariadb_pod}" ]]; then
        local db_svc
        db_svc=$(try_secret_keys "${NAMESPACE}" "${db_secret}" \
            databaseService database-service DB_HOST)
        if [[ -n "${db_svc}" ]]; then
            mariadb_pod=$(find_pod_by_name "${NAMESPACE}" "${db_svc}")
        fi
    fi

    if [[ -z "${mariadb_pod}" ]]; then
        log_error "No MariaDB/MySQL pod found in namespace ${NAMESPACE}"
        log_info "Pods in namespace:"
        oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null || echo "  (none)"
        exit 1
    fi

    log_info "MariaDB pod: ${mariadb_pod}"

    # 4. Detect client command
    local client_cmd
    client_cmd=$(detect_client_cmd "${NAMESPACE}" "${mariadb_pod}")

    if [[ -z "${client_cmd}" ]]; then
        log_error "Neither mariadb nor mysql client found in pod ${mariadb_pod}"
        exit 1
    fi

    log_info "Client command: ${client_cmd}"

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would restore ${line_count}-line SQL dump to database ${db_name}"
        log_info "[DRY RUN] Target pod: ${mariadb_pod}"
        log_info "[DRY RUN] Client: ${client_cmd}"
        log_info "[DRY RUN] Dump header:"
        head -5 "${dump_file}" | sed 's/^/  /'
        return
    fi

    # 5. Restore
    log_info "Restoring database from dump..."
    local restore_err
    restore_err=$(oc exec -i -n "${NAMESPACE}" -c mariadb "${mariadb_pod}" -- \
        "${client_cmd}" -u"${db_user}" -p"${db_pass}" "${db_name}" \
        < "${dump_file}" 2>&1 >/dev/null) || true

    # Check for real errors (ignore SETVAL output and warnings)
    if echo "${restore_err}" | grep -qi "^ERROR"; then
        log_error "Database restore failed: ${restore_err}"
        exit 1
    fi

    # 6. Verify
    log_info "Verifying restore..."
    local table_count
    table_count=$(oc exec -n "${NAMESPACE}" -c mariadb "${mariadb_pod}" -- \
        "${client_cmd}" -u"${db_user}" -p"${db_pass}" "${db_name}" \
        -N -e 'SHOW TABLES;' 2>/dev/null | wc -l || echo "0")

    log_info "Tables in database after restore: ${table_count}"
    log_info "Database restore completed successfully!"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
case "${STORAGE_FORMAT}" in
    PVC|pvc)       restore_pvc ;;
    DATABASE|database|DB|db) restore_database ;;
    *)
        log_error "Unknown storage format: ${STORAGE_FORMAT}"
        log_error "Expected PVC or DATABASE"
        exit 1
        ;;
esac

# Summary
echo ""
log_info "=========================================="
log_info "Restore Summary"
log_info "=========================================="
log_info "Namespace: ${NAMESPACE}"
log_info "Storage format: ${STORAGE_FORMAT}"
log_info "Backup path: ${BACKUP_PATH}"
if [[ "${DRY_RUN}" == true ]]; then
    log_info "DRY RUN completed - no changes were made"
else
    log_info "Restore completed successfully"
fi
log_info "=========================================="

exit 0
