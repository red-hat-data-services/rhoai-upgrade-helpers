#!/usr/bin/env bash
set -euo pipefail

# This script migrates GuardrailsOrchestrator spec.otelExporter from the RHOAI 2.25 schema
# (protocol/tracesProtocol/metricsProtocol + otlpEndpoint/tracesEndpoint/metricsEndpoint + otlpExport)
# to the current schema (otlpProtocol + otlpTracesEndpoint/otlpMetricsEndpoint + enableTraces/enableMetrics).
#
# Intended usage: run AFTER upgrading to the operator version that contains the new schema.

usage() {
  cat <<'EOF'
Usage: ./migrate-gorch-otel-exporter.sh --namespace <namespace> [--check|--fix] [--dry-run]

Migrates GuardrailsOrchestrator .spec.otelExporter from the RHOAI 2.25 field names to the current ones.

Modes:
  --check   Report which CRs need migration (default)
  --fix     Patch CRs in-place and wait for rollouts

Options:
  -n, --namespace <name>  Namespace to scan (required)
  --dry-run               Print the patch that would be applied (implies --check, no changes)
  -h, --help              Show help

Notes:
  - If you used per-signal protocols on RHOAI 2.25 (tracesProtocol/metricsProtocol),
    the new schema only supports a single protocol. This script will warn and pick one.
  - otlpEndpoint (single endpoint) will be mapped to BOTH otlpTracesEndpoint and otlpMetricsEndpoint.

EOF
}

NAMESPACE=""
MODE="check"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      NAMESPACE="${2:-}"
      shift 2
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
      DRY_RUN="true"
      MODE="check"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${NAMESPACE}" ]]; then
  echo "ERROR: --namespace is required" >&2
  usage
  exit 1
fi

if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: Required command not found: oc" >&2
  exit 1
fi

if ! oc whoami &>/dev/null; then
  echo "ERROR: You are not logged in to the cluster" >&2
  exit 1
fi

if ! oc get namespace "${NAMESPACE}" &>/dev/null; then
  echo "ERROR: Namespace ${NAMESPACE} does not exist" >&2
  exit 1
fi

echo "Checking for GuardrailsOrchestrator CRs in namespace ${NAMESPACE}"
GORCH_NAMES_RAW="$(oc get guardrailsorchestrator -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

if [[ -z "${GORCH_NAMES_RAW}" ]]; then
  echo "No GuardrailsOrchestrator CRs found in namespace ${NAMESPACE}."
  exit 0
fi

mapfile -t GORCH_NAMES < <(printf "%s" "${GORCH_NAMES_RAW}" | awk 'NF')
GORCH_COUNT="${#GORCH_NAMES[@]}"
echo "Found ${GORCH_COUNT} GuardrailsOrchestrator CR(s) in namespace ${NAMESPACE}"

PATCHED_COUNT=0
NEEDS_MIGRATION=0
SKIPPED=0
FAILED=0
FAILED_CRS=()

json_escape() {
  local s="${1}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "\"${s}\""
}

add_json_field() {
  local key="$1"
  local json_value="$2"
  if [[ -z "${json_value}" ]]; then
    return 0
  fi
  if [[ "${_json_first}" == "true" ]]; then
    _json_first="false"
  else
    _json_buf+=","
  fi
  _json_buf+="\"${key}\":${json_value}"
}

otel_needs_migration() {
  # Returns 0 if any "old schema" keys are present.
  [[ -n "${old_protocol}" || -n "${old_traces_protocol}" || -n "${old_metrics_protocol}" || -n "${old_otlp_endpoint}" || -n "${old_traces_endpoint}" || -n "${old_metrics_endpoint}" || -n "${old_otlp_export}" ]]
}

otel_is_new_only() {
  [[ -n "${new_otlp_protocol}" || -n "${new_traces_endpoint}" || -n "${new_metrics_endpoint}" || -n "${new_enable_traces}" || -n "${new_enable_metrics}" ]] && \
  [[ -z "${old_protocol}" && -z "${old_traces_protocol}" && -z "${old_metrics_protocol}" && -z "${old_otlp_endpoint}" && -z "${old_traces_endpoint}" && -z "${old_metrics_endpoint}" && -z "${old_otlp_export}" ]]
}

echo

for CR_NAME in "${GORCH_NAMES[@]}"; do
  # Old schema fields (RHOAI 2.25)
  old_protocol="$(oc get guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" -o jsonpath='{.spec.otelExporter.protocol}' 2>/dev/null || true)"
  old_traces_protocol="$(oc get guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" -o jsonpath='{.spec.otelExporter.tracesProtocol}' 2>/dev/null || true)"
  old_metrics_protocol="$(oc get guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" -o jsonpath='{.spec.otelExporter.metricsProtocol}' 2>/dev/null || true)"
  old_otlp_endpoint="$(oc get guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" -o jsonpath='{.spec.otelExporter.otlpEndpoint}' 2>/dev/null || true)"
  old_traces_endpoint="$(oc get guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" -o jsonpath='{.spec.otelExporter.tracesEndpoint}' 2>/dev/null || true)"
  old_metrics_endpoint="$(oc get guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" -o jsonpath='{.spec.otelExporter.metricsEndpoint}' 2>/dev/null || true)"
  old_otlp_export="$(oc get guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" -o jsonpath='{.spec.otelExporter.otlpExport}' 2>/dev/null || true)"

  # New schema fields (RHOAI 3.x)
  new_otlp_protocol="$(oc get guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" -o jsonpath='{.spec.otelExporter.otlpProtocol}' 2>/dev/null || true)"
  new_traces_endpoint="$(oc get guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" -o jsonpath='{.spec.otelExporter.otlpTracesEndpoint}' 2>/dev/null || true)"
  new_metrics_endpoint="$(oc get guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" -o jsonpath='{.spec.otelExporter.otlpMetricsEndpoint}' 2>/dev/null || true)"
  new_enable_traces="$(oc get guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" -o jsonpath='{.spec.otelExporter.enableTraces}' 2>/dev/null || true)"
  new_enable_metrics="$(oc get guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" -o jsonpath='{.spec.otelExporter.enableMetrics}' 2>/dev/null || true)"

  # Nothing configured at all
  if [[ -z "${old_protocol}${old_traces_protocol}${old_metrics_protocol}${old_otlp_endpoint}${old_traces_endpoint}${old_metrics_endpoint}${old_otlp_export}${new_otlp_protocol}${new_traces_endpoint}${new_metrics_endpoint}${new_enable_traces}${new_enable_metrics}" ]]; then
    echo "${CR_NAME}: no spec.otelExporter configured, skipping"
    ((SKIPPED++)) || true
    continue
  fi

  if otel_is_new_only; then
    echo "${CR_NAME}: already on new otelExporter schema"
    ((SKIPPED++)) || true
    continue
  fi

  if ! otel_needs_migration; then
    echo "${CR_NAME}: unknown otelExporter schema; leaving untouched"
    ((SKIPPED++)) || true
    continue
  fi

  ((NEEDS_MIGRATION++)) || true

  # Choose protocol (new schema only supports a single protocol)
  chosen_protocol=""
  if [[ -n "${old_protocol}" ]]; then
    chosen_protocol="${old_protocol}"
  elif [[ -n "${old_traces_protocol}" && -n "${old_metrics_protocol}" ]]; then
    if [[ "${old_traces_protocol}" != "${old_metrics_protocol}" ]]; then
      echo "WARNING: ${CR_NAME}: tracesProtocol and metricsProtocol differ; new schema supports a single protocol. Using a best-effort choice."
    fi
    chosen_protocol="${old_traces_protocol}"
  elif [[ -n "${old_traces_protocol}" ]]; then
    chosen_protocol="${old_traces_protocol}"
  elif [[ -n "${old_metrics_protocol}" ]]; then
    chosen_protocol="${old_metrics_protocol}"
  fi

  # Map endpoints
  mapped_traces_endpoint="${old_traces_endpoint:-${old_otlp_endpoint}}"
  mapped_metrics_endpoint="${old_metrics_endpoint:-${old_otlp_endpoint}}"

  # Map export selection -> enable flags
  enable_traces=""
  enable_metrics=""
  if [[ -n "${old_otlp_export}" ]]; then
    export_lc="$(printf '%s' "${old_otlp_export}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${export_lc}" == *"all"* || "${export_lc}" == *"traces"* || "${export_lc}" == *"trace"* ]]; then
      enable_traces="true"
    fi
    if [[ "${export_lc}" == *"all"* || "${export_lc}" == *"metrics"* || "${export_lc}" == *"metric"* ]]; then
      enable_metrics="true"
    fi
  fi

  # Build new otelExporter object JSON (only include fields we can infer)
  _json_buf="{"
  _json_first="true"
  add_json_field "otlpProtocol" "$( [[ -n "${chosen_protocol}" ]] && json_escape "${chosen_protocol}" || true )"
  add_json_field "otlpTracesEndpoint" "$( [[ -n "${mapped_traces_endpoint}" ]] && json_escape "${mapped_traces_endpoint}" || true )"
  add_json_field "otlpMetricsEndpoint" "$( [[ -n "${mapped_metrics_endpoint}" ]] && json_escape "${mapped_metrics_endpoint}" || true )"
  add_json_field "enableTraces" "${enable_traces}"
  add_json_field "enableMetrics" "${enable_metrics}"
  _json_buf+="}"

  if [[ "${_json_first}" == "true" ]]; then
    echo "${CR_NAME}: found old-schema otelExporter but could not infer any new fields; leaving untouched"
    ((SKIPPED++)) || true
    continue
  fi

  PATCH="{\"spec\":{\"otelExporter\":${_json_buf}}}"
  echo "${CR_NAME}: needs migration"
  echo "  patch: ${PATCH}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    continue
  fi

  if [[ "${MODE}" != "fix" ]]; then
    continue
  fi

  echo "  applying patch..."
  if ! oc patch guardrailsorchestrator -n "${NAMESPACE}" "${CR_NAME}" --type=merge -p "${PATCH}" >/dev/null; then
    echo "  ERROR: failed to patch CR ${CR_NAME}"
    ((FAILED++)) || true
    FAILED_CRS+=("${CR_NAME}")
    continue
  fi

  # Best-effort rollout wait: deployment name is typically the CR name
  if oc get deployment -n "${NAMESPACE}" "${CR_NAME}" &>/dev/null; then
    if ! oc rollout status deployment -n "${NAMESPACE}" "${CR_NAME}" --timeout=120s >/dev/null; then
      echo "  WARNING: rollout did not complete within timeout for deployment ${CR_NAME}"
    fi
  fi

  echo "  migrated"
  ((PATCHED_COUNT++)) || true
done

echo
echo "GuardrailsOrchestrator otelExporter migration summary"
echo "  namespace:                   ${NAMESPACE}"
echo "  CRs found:                    ${GORCH_COUNT}"
echo "  need migration (old schema):  ${NEEDS_MIGRATION}"
echo "  migrated:                     ${PATCHED_COUNT}"
echo "  skipped:                      ${SKIPPED}"
echo "  failed:                       ${FAILED}"

if [[ "${FAILED}" -gt 0 ]]; then
  echo "Failed CRs: ${FAILED_CRS[*]}" >&2
  exit 1
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry run complete."
fi

exit 0

