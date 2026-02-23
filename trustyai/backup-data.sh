#!/usr/bin/env bash

#
# TrustyAI Data Storage Backup Script
#
# Backs up TrustyAI data storage (PVC or database).
# Auto-detects the storage type from the TrustyAIService CR.
#
# PVC:      rsyncs directly from the running TrustyAI service pod
#           (no temporary pod, no image pull — works on disconnected clusters)
# DATABASE: dumps MariaDB via the existing database pod
#

set -euo pipefail

# Configuration
NAMESPACE="${TRUSTYAI_NAMESPACE:-}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
TAS_NAME=""

# Functions
log_info()  { echo "[INFO] $1"; }
log_warn()  { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1" >&2; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Backup TrustyAI data storage (PVC or database) to a local directory.

The script auto-detects the storage type from the TrustyAIService CR
and performs the appropriate backup:
  - PVC:      rsyncs files from the running TrustyAI service pod
  - DATABASE: dumps the MariaDB database to a SQL file

No temporary pods or external images are required.

OPTIONS:
    -n, --namespace NAMESPACE    OpenShift namespace (required)
    -d, --backup-dir DIR         Backup directory (default: ./backups)
    -s, --service-name NAME      TrustyAIService name (default: auto-detect)
    -h, --help                   Show this help message

ENVIRONMENT VARIABLES:
    TRUSTYAI_NAMESPACE          Alternative to -n flag
    BACKUP_DIR                  Alternative to -d flag

EXAMPLES:
    $0 -n my-namespace
    $0 -n my-namespace -d /tmp/backups
    $0 -n my-namespace -s trustyai-service

EOF
    exit 1
}

# ──────────────────────────────────────────────
# Find a running pod by label selectors (tries multiple selectors in order)
# Usage: find_pod_by_labels <namespace> <label1> [label2] ...
# Returns the first Running pod found, or empty string.
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

# ──────────────────────────────────────────────
# Find a pod by name substring (fallback when labels don't work)
# Usage: find_pod_by_name <namespace> <substring>
# ──────────────────────────────────────────────
find_pod_by_name() {
    local ns="$1" pattern="$2"
    oc get pods -n "${ns}" --field-selector=status.phase=Running \
        --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null \
        | grep -i "${pattern}" | head -1 || echo ""
}

# ──────────────────────────────────────────────
# Try to extract a secret key, attempting multiple key names
# Usage: try_secret_keys <namespace> <secret> <key1> [key2] ...
# ──────────────────────────────────────────────
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

# ──────────────────────────────────────────────
# Detect which dump command is available inside a pod
# Usage: detect_dump_cmd <namespace> <pod>
# ──────────────────────────────────────────────
detect_dump_cmd() {
    local ns="$1" pod="$2"
    for cmd in mariadb-dump mysqldump; do
        if oc exec -n "${ns}" -c mariadb "${pod}" -- which "${cmd}" &>/dev/null; then
            echo "${cmd}"
            return 0
        fi
    done
    echo ""
}

# ──────────────────────────────────────────────
# Detect which client command is available inside a pod
# Usage: detect_client_cmd <namespace> <pod>
# ──────────────────────────────────────────────
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
        -d|--backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        -s|--service-name) TAS_NAME="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Validate
if [[ -z "${NAMESPACE}" ]]; then
    log_error "Namespace is required. Use -n flag or set TRUSTYAI_NAMESPACE environment variable."
    usage
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

# Auto-detect TrustyAIService name
if [[ -z "${TAS_NAME}" ]]; then
    TAS_NAME=$(oc get trustyaiservice -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "${TAS_NAME}" ]]; then
        log_error "No TrustyAIService found in namespace ${NAMESPACE}"
        exit 1
    fi
fi

log_info "Starting TrustyAI data backup..."
log_info "Namespace: ${NAMESPACE}"
log_info "TrustyAIService: ${TAS_NAME}"
log_info "Backup directory: ${BACKUP_DIR}"

# Detect storage type from CR
STORAGE_FORMAT=$(oc get trustyaiservice "${TAS_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.storage.format}' 2>/dev/null || echo "")

if [[ -z "${STORAGE_FORMAT}" ]]; then
    STORAGE_FORMAT="PVC"
    log_info "Storage format not set in CR, defaulting to PVC"
else
    log_info "Storage format: ${STORAGE_FORMAT}"
fi

mkdir -p "${BACKUP_DIR}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ──────────────────────────────────────────────
# PVC backup — rsync directly from the TrustyAI service pod
# ──────────────────────────────────────────────
backup_pvc() {
    log_info "Starting PVC backup..."

    # 1. Find the TrustyAI service pod (try operator labels, then name match)
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

    # 2. Find the PVC mount path from the pod spec
    #    The operator uses PVC name "<instance>-pvc" and volume name "volume".
    #    We look for any volumeMount backed by a PVC to be resilient.
    local mount_path pvc_name

    # Try the known operator convention first: volume named "volume"
    mount_path=$(oc get pod "${tas_pod}" -n "${NAMESPACE}" -o json 2>/dev/null \
        | jq -r '
            .spec.containers[0].volumeMounts[]
            | select(.name == "volume")
            | .mountPath' 2>/dev/null || echo "")

    if [[ -n "${mount_path}" ]]; then
        pvc_name=$(oc get pod "${tas_pod}" -n "${NAMESPACE}" -o json 2>/dev/null \
            | jq -r '
                .spec.volumes[]
                | select(.name == "volume")
                | .persistentVolumeClaim.claimName' 2>/dev/null || echo "")
    fi

    # Fallback: find any volume mount backed by a PVC containing "trustyai" or the TAS name
    if [[ -z "${mount_path}" ]]; then
        local vol_info
        vol_info=$(oc get pod "${tas_pod}" -n "${NAMESPACE}" -o json 2>/dev/null \
            | jq -r --arg tas "${TAS_NAME}" '
                .spec.volumes[] as $v
                | select($v.persistentVolumeClaim != null)
                | select($v.persistentVolumeClaim.claimName | test($tas; "i"))
                | {
                    volName: $v.name,
                    pvcName: $v.persistentVolumeClaim.claimName
                }' 2>/dev/null | head -1 || echo "")

        if [[ -n "${vol_info}" ]]; then
            local vol_name
            vol_name=$(echo "${vol_info}" | jq -r '.volName')
            pvc_name=$(echo "${vol_info}" | jq -r '.pvcName')
            mount_path=$(oc get pod "${tas_pod}" -n "${NAMESPACE}" -o json 2>/dev/null \
                | jq -r --arg vn "${vol_name}" '
                    .spec.containers[0].volumeMounts[]
                    | select(.name == $vn)
                    | .mountPath' 2>/dev/null || echo "")
        fi
    fi

    # Last resort: read from the CR's spec.storage.folder
    if [[ -z "${mount_path}" ]]; then
        mount_path=$(oc get trustyaiservice "${TAS_NAME}" -n "${NAMESPACE}" \
            -o jsonpath='{.spec.storage.folder}' 2>/dev/null || echo "")
        pvc_name="${TAS_NAME}-pvc"
    fi

    if [[ -z "${mount_path}" ]]; then
        log_error "Could not determine PVC mount path from pod or CR"
        log_info "Pod volume mounts:"
        oc get pod "${tas_pod}" -n "${NAMESPACE}" -o jsonpath='{range .spec.containers[0].volumeMounts[*]}{.name}: {.mountPath}{"\n"}{end}' 2>/dev/null
        exit 1
    fi

    log_info "PVC: ${pvc_name:-unknown}"
    log_info "Mount path: ${mount_path}"

    # 3. Rsync data from the running pod into a data/ subdirectory
    local backup_dir="${BACKUP_DIR}/trustyai-data-${NAMESPACE}-${TIMESTAMP}"
    local data_dir="${backup_dir}/data"
    mkdir -p "${data_dir}"

    log_info "Copying data from ${tas_pod}:${mount_path}/ ..."

    # The operator hardcodes the container name as "trustyai-service".
    # Specifying it explicitly avoids ambiguity with the kube-rbac-proxy sidecar.
    oc rsync -n "${NAMESPACE}" -c trustyai-service "${tas_pod}:${mount_path}/" "${data_dir}/"

    # 4. Verify
    local file_count
    file_count=$(find "${data_dir}" -type f | wc -l)

    if [[ "${file_count}" -eq 0 ]]; then
        log_warn "PVC appears to be empty (0 files copied)"
    else
        log_info "Copied ${file_count} file(s)"
    fi

    # 5. Save metadata alongside data/ (inside the backup dir, but not inside data/)
    local meta_file="${backup_dir}/metadata.json"
    cat > "${meta_file}" << METAEOF
{
  "timestamp": "${TIMESTAMP}",
  "namespace": "${NAMESPACE}",
  "trustyaiService": "${TAS_NAME}",
  "storageFormat": "PVC",
  "pvcName": "${pvc_name:-unknown}",
  "mountPath": "${mount_path}",
  "sourcePod": "${tas_pod}",
  "fileCount": ${file_count}
}
METAEOF

    log_info "Backup completed successfully!"
    log_info "Backup directory: ${backup_dir}"
}

# ──────────────────────────────────────────────
# Database backup — dump from the existing MariaDB pod
# ──────────────────────────────────────────────
backup_database() {
    log_info "Starting database backup..."

    # 1. Find the database credentials secret
    #    The CR field spec.storage.databaseConfigurations names the secret explicitly.
    #    If unset, the operator falls back to <instance-name>-db-credentials.
    local db_secret=""

    # Try the CR-specified secret name first
    db_secret=$(oc get trustyaiservice "${TAS_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.storage.databaseConfigurations}' 2>/dev/null || echo "")

    if [[ -n "${db_secret}" ]]; then
        if ! oc get secret "${db_secret}" -n "${NAMESPACE}" &>/dev/null; then
            log_warn "Secret '${db_secret}' from CR spec.storage.databaseConfigurations not found, searching..."
            db_secret=""
        fi
    fi

    # Try operator default convention
    if [[ -z "${db_secret}" ]] && oc get secret "${TAS_NAME}-db-credentials" -n "${NAMESPACE}" &>/dev/null; then
        db_secret="${TAS_NAME}-db-credentials"
    fi

    # Fallback: search for db-credentials pattern
    if [[ -z "${db_secret}" ]]; then
        db_secret=$(oc get secret -n "${NAMESPACE}" --no-headers \
            -o custom-columns='NAME:.metadata.name' 2>/dev/null \
            | grep -i 'db-credentials' | head -1 || echo "")
    fi

    # Fallback: search for mariadb pattern
    if [[ -z "${db_secret}" ]]; then
        db_secret=$(oc get secret -n "${NAMESPACE}" --no-headers \
            -o custom-columns='NAME:.metadata.name' 2>/dev/null \
            | grep -i 'mariadb' | head -1 || echo "")
    fi

    if [[ -z "${db_secret}" ]]; then
        log_error "No database credentials secret found in namespace ${NAMESPACE}"
        log_info "Tried: ${TAS_NAME}-db-credentials, *db-credentials*, *mariadb*"
        log_info "Available secrets (non-system):"
        oc get secret -n "${NAMESPACE}" --no-headers \
            -o custom-columns='NAME:.metadata.name' 2>/dev/null \
            | grep -v 'kubernetes.io\|openshift\|builder\|deployer\|default' || echo "  (none)"
        exit 1
    fi

    log_info "Credentials secret: ${db_secret}"

    # 2. Extract credentials (try operator keys, then common alternatives)
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
    #    Operator convention: pod named mariadb-<tas-name>-*
    #    Also try StatefulSet pods and label-based discovery
    local mariadb_pod=""

    # Try operator naming convention
    mariadb_pod=$(find_pod_by_name "${NAMESPACE}" "mariadb-${TAS_NAME}")

    # Try generic mariadb name
    if [[ -z "${mariadb_pod}" ]]; then
        mariadb_pod=$(find_pod_by_name "${NAMESPACE}" "mariadb")
    fi

    # Try mysql name (some setups use mysql-compatible pods)
    if [[ -z "${mariadb_pod}" ]]; then
        mariadb_pod=$(find_pod_by_name "${NAMESPACE}" "mysql")
    fi

    # Try looking up via the service name from the secret
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

    # 4. Detect available dump command
    #    Try mariadb-dump / mysqldump first. If neither exists, fall back to
    #    the mariadb/mysql client with a SQL-based dump script.
    local dump_cmd dump_method
    dump_cmd=$(detect_dump_cmd "${NAMESPACE}" "${mariadb_pod}")

    if [[ -n "${dump_cmd}" ]]; then
        dump_method="native"
        log_info "Dump command: ${dump_cmd}"
    else
        dump_cmd=$(detect_client_cmd "${NAMESPACE}" "${mariadb_pod}")
        if [[ -n "${dump_cmd}" ]]; then
            dump_method="client"
            log_info "No dump tool found, using ${dump_cmd} client with SQL-based dump"
        else
            log_error "No MariaDB/MySQL client found in pod ${mariadb_pod}"
            exit 1
        fi
    fi

    # 5. Dump the database into a backup directory
    local backup_dir="${BACKUP_DIR}/trustyai-db-${NAMESPACE}-${TIMESTAMP}"
    mkdir -p "${backup_dir}"
    local dump_file="${backup_dir}/dump.sql"
    log_info "Dumping database to ${dump_file}..."

    if [[ "${dump_method}" == "native" ]]; then
        # Use mariadb-dump / mysqldump directly
        # --skip-lock-tables is needed for Galera clusters (LOCK TABLE on SEQUENCES not supported)
        oc exec -n "${NAMESPACE}" -c mariadb "${mariadb_pod}" -- \
            "${dump_cmd}" --skip-lock-tables -u"${db_user}" -p"${db_pass}" "${db_name}" \
            > "${dump_file}" 2>/dev/null
        local dump_exit=$?
        # Exit code 2 with output is acceptable (warnings like Galera lock issues)
        if [[ "${dump_exit}" -ne 0 ]] && [[ ! -s "${dump_file}" ]]; then
            log_error "Database dump failed (exit code ${dump_exit}, no output)"
            rm -rf "${backup_dir}"
            exit 1
        fi
    else
        # Fall back: use the mariadb/mysql client to generate a SQL dump
        # via SHOW CREATE TABLE + SELECT INTO OUTFILE equivalent
        local dump_script
        dump_script=$(cat <<'SQLSCRIPT'
SET @db = DATABASE();

-- Header
SELECT CONCAT('-- SQL dump via mariadb client\n-- Database: ', @db, '\n-- Date: ', NOW(), '\n');

-- Disable checks for import
SELECT 'SET FOREIGN_KEY_CHECKS=0;';
SELECT 'SET UNIQUE_CHECKS=0;';
SELECT '';

-- For each table: DROP + CREATE + INSERT
SELECT CONCAT('-- Table: ', table_name)
FROM information_schema.tables
WHERE table_schema = @db AND table_type = 'BASE TABLE';

SQLSCRIPT
)
        # Generate a dump using a single script that outputs CREATE and INSERT statements
        if ! oc exec -n "${NAMESPACE}" -c mariadb "${mariadb_pod}" -- \
            "${dump_cmd}" -u"${db_user}" -p"${db_pass}" "${db_name}" \
            --batch --skip-column-names \
            -e "SELECT CONCAT('-- SQL dump via ${dump_cmd} client') AS '';
                SELECT CONCAT('-- Database: ${db_name}') AS '';
                SELECT CONCAT('-- Date: ', NOW()) AS '';
                SELECT '' AS '';
                SELECT 'SET FOREIGN_KEY_CHECKS=0;' AS '';
                SELECT 'SET UNIQUE_CHECKS=0;' AS '';" \
            > "${dump_file}" 2>/dev/null; then
            log_error "Database dump header failed"
            rm -rf "${backup_dir}"
            exit 1
        fi

        # Get list of tables and dump each one
        local tables
        tables=$(oc exec -n "${NAMESPACE}" -c mariadb "${mariadb_pod}" -- \
            "${dump_cmd}" -u"${db_user}" -p"${db_pass}" "${db_name}" \
            --batch --skip-column-names \
            -e "SHOW TABLES;" 2>/dev/null)

        if [[ -z "${tables}" ]]; then
            log_warn "No tables found in database ${db_name}"
        else
            for table in ${tables}; do
                log_info "  Dumping table: ${table}"

                # CREATE TABLE
                echo "" >> "${dump_file}"
                echo "-- Table: ${table}" >> "${dump_file}"
                oc exec -n "${NAMESPACE}" -c mariadb "${mariadb_pod}" -- \
                    "${dump_cmd}" -u"${db_user}" -p"${db_pass}" "${db_name}" \
                    --batch --skip-column-names \
                    -e "SELECT CONCAT('DROP TABLE IF EXISTS \`${table}\`;') AS '';" \
                    >> "${dump_file}" 2>/dev/null

                oc exec -n "${NAMESPACE}" -c mariadb "${mariadb_pod}" -- \
                    "${dump_cmd}" -u"${db_user}" -p"${db_pass}" "${db_name}" \
                    --batch --skip-column-names \
                    -e "SHOW CREATE TABLE \`${table}\`;" \
                    2>/dev/null | awk 'NR==1{$1=""; print substr($0,2) ";"}' \
                    >> "${dump_file}"

                # INSERT statements (one per row)
                local columns
                columns=$(oc exec -n "${NAMESPACE}" -c mariadb "${mariadb_pod}" -- \
                    "${dump_cmd}" -u"${db_user}" -p"${db_pass}" "${db_name}" \
                    --batch --skip-column-names \
                    -e "SELECT GROUP_CONCAT(CONCAT('\`', column_name, '\`'))
                        FROM information_schema.columns
                        WHERE table_schema='${db_name}' AND table_name='${table}'
                        ORDER BY ordinal_position;" 2>/dev/null)

                if [[ -n "${columns}" ]]; then
                    oc exec -n "${NAMESPACE}" -c mariadb "${mariadb_pod}" -- \
                        "${dump_cmd}" -u"${db_user}" -p"${db_pass}" "${db_name}" \
                        --batch --raw \
                        -e "SELECT CONCAT(
                                'INSERT INTO \`${table}\` (${columns}) VALUES (',
                                GROUP_CONCAT(
                                    IF(c.val IS NULL, 'NULL',
                                       CONCAT('''', REPLACE(c.val, '''', ''''''), ''''))
                                ),
                                ');'
                            )
                            FROM (
                                SELECT t.*, ROW_NUMBER() OVER () AS _rn
                                FROM \`${table}\` t
                            ) numbered
                            CROSS JOIN LATERAL (
                                SELECT ordinal_position,
                                       CAST(COLUMN_GET(numbered.*, column_name AS CHAR) AS CHAR) AS val
                                FROM information_schema.columns
                                WHERE table_schema='${db_name}' AND table_name='${table}'
                                ORDER BY ordinal_position
                            ) c
                            GROUP BY _rn;" \
                        >> "${dump_file}" 2>/dev/null || {
                        # Simpler fallback: use SELECT INTO OUTFILE syntax won't work,
                        # so just dump as tab-separated and note it
                        log_warn "  Complex INSERT generation failed for ${table}, using simple format"
                        echo "-- Raw data for ${table} (tab-separated):" >> "${dump_file}"
                        oc exec -n "${NAMESPACE}" -c mariadb "${mariadb_pod}" -- \
                            "${dump_cmd}" -u"${db_user}" -p"${db_pass}" "${db_name}" \
                            --batch \
                            -e "SELECT * FROM \`${table}\`;" \
                            >> "${dump_file}" 2>/dev/null
                    }
                fi
            done
        fi

        # Re-enable checks
        echo "" >> "${dump_file}"
        echo "SET FOREIGN_KEY_CHECKS=1;" >> "${dump_file}"
        echo "SET UNIQUE_CHECKS=1;" >> "${dump_file}"
    fi

    # 6. Verify the dump
    local line_count
    line_count=$(wc -l < "${dump_file}")

    if [[ "${line_count}" -le 1 ]]; then
        log_error "Database dump appears empty (${line_count} lines)"
        log_error "First line: $(head -1 "${dump_file}")"
        rm -rf "${backup_dir}"
        exit 1
    fi

    log_info "Database dump: ${line_count} lines"

    # 7. Save metadata alongside the dump
    local meta_file="${backup_dir}/metadata.json"
    cat > "${meta_file}" << METAEOF
{
  "timestamp": "${TIMESTAMP}",
  "namespace": "${NAMESPACE}",
  "trustyaiService": "${TAS_NAME}",
  "storageFormat": "DATABASE",
  "mariadbPod": "${mariadb_pod}",
  "credentialsSecret": "${db_secret}",
  "databaseName": "${db_name}",
  "databaseUser": "${db_user}",
  "dumpCommand": "${dump_cmd}",
  "dumpMethod": "${dump_method}",
  "dumpLines": ${line_count}
}
METAEOF

    log_info "Backup completed successfully!"
    log_info "Backup directory: ${backup_dir}"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
case "${STORAGE_FORMAT}" in
    PVC|pvc)       backup_pvc ;;
    DATABASE|database|DB|db) backup_database ;;
    *)
        log_error "Unknown storage format: ${STORAGE_FORMAT}"
        log_error "Expected PVC or DATABASE"
        exit 1
        ;;
esac

exit 0
