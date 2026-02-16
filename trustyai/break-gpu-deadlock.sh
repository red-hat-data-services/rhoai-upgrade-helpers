#!/usr/bin/env bash
# Detects and fixes GPU deployment deadlocks when TrustyAI patches InferenceServices

set -euo pipefail

NAMESPACE=""
MODE="check"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
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
        -h|--help)
            echo "Usage: $0 --namespace <namespace> [--check|--fix]"
            echo ""
            echo "Options:"
            echo "  -n, --namespace <name>  Namespace to scan"
            echo "  --check                 Check for deadlocks (default)"
            echo "  --fix                   Fix detected deadlocks"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [[ -z "$NAMESPACE" ]]; then
    echo "Error: --namespace is required"
    echo "Use --help for usage information"
    exit 1
fi

# Get all InferenceService names
isvcs=$(oc get pods -n "$NAMESPACE" -l component=predictor -o jsonpath='{.items[*].metadata.labels.serving\.kserve\.io/inferenceservice}' 2>/dev/null | tr ' ' '\n' | sort -u)

found=false

for isvc in $isvcs; do
    # Get Running and Pending predictor pods for this InferenceService
    running=$(oc get pods -n "$NAMESPACE" -l "serving.kserve.io/inferenceservice=$isvc" \
        --field-selector=status.phase=Running -o name 2>/dev/null | head -1)
    pending=$(oc get pods -n "$NAMESPACE" -l "serving.kserve.io/inferenceservice=$isvc" \
        --field-selector=status.phase=Pending -o name 2>/dev/null | head -1)

    # Deadlock = both Running and Pending exist
    if [[ -n "$running" ]] && [[ -n "$pending" ]]; then
        found=true
        echo "DEADLOCK: $isvc"
        echo "  Running: $(basename $running)"
        echo "  Pending: $(basename $pending)"
        echo ""

        if [[ "$MODE" == "fix" ]]; then
            oc delete -n "$NAMESPACE" "$running"
            oc wait --for=condition=Ready -n "$NAMESPACE" "$pending" --timeout=300s 2>/dev/null && echo "✓ Fixed" || echo "Check: oc get pods -n $NAMESPACE"
        else
            echo "To fix: $0 --namespace $NAMESPACE --fix"
        fi
        echo ""
    fi
done

[[ "$found" == "false" ]] && echo "No deadlocks detected"
