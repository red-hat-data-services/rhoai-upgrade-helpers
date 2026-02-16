#!/bin/bash

# Script to backup all LlamaStackDistribution resources before RHOAI upgrade
# This script must be run by a cluster administrator with access to all namespaces

set -e

BACKUP_DIR="${BACKUP_DIR:-./llamastack-backups-$(date +%Y%m%d-%H%M%S)}"

# Track LLSDs with custom configs for warning at the end (using temp file due to subshell)
CUSTOM_CONFIG_FILE=$(mktemp)
trap "rm -f $CUSTOM_CONFIG_FILE" EXIT

CLUSTER_URL=$(oc whoami --show-server 2>/dev/null || echo "unknown")
CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")

echo "=========================================="
echo "LlamaStack Backup Script"
echo "=========================================="
echo "Cluster:          $CLUSTER_URL"
echo "Cluster version:  $CLUSTER_VERSION"
echo "Backup directory: $BACKUP_DIR"
echo ""

# Create backup directory with restrictive permissions
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# Get all LlamaStackDistribution resources
echo "Finding all LlamaStackDistribution resources..."
LLSD_LIST=$(oc get llamastackdistribution --all-namespaces -o json)

# Check if any LLSDs exist
LLSD_COUNT=$(echo "$LLSD_LIST" | jq -r '.items | length')
if [ "$LLSD_COUNT" -eq 0 ]; then
    echo "No LlamaStackDistribution resources found in the cluster."
    exit 0
fi

echo "Found $LLSD_COUNT LlamaStackDistribution resource(s)"
echo ""

# Process each LlamaStackDistribution
echo "$LLSD_LIST" | jq -c '.items[]' | while read -r llsd; do
    NAMESPACE=$(echo "$llsd" | jq -r '.metadata.namespace')
    NAME=$(echo "$llsd" | jq -r '.metadata.name')

    echo "----------------------------------------"
    echo "Processing: $NAME in namespace $NAMESPACE"
    echo "----------------------------------------"

    # Create directory for this LLSD with restrictive permissions
    LLSD_DIR="$BACKUP_DIR/$NAMESPACE/$NAME"
    mkdir -p "$LLSD_DIR"
    chmod 700 "$BACKUP_DIR/$NAMESPACE"
    chmod 700 "$LLSD_DIR"

    # 1. Backup the LlamaStackDistribution YAML
    echo "  [1/3] Backing up LlamaStackDistribution YAML..."
    oc get llamastackdistribution "$NAME" -n "$NAMESPACE" -o yaml > "$LLSD_DIR/llamastackdistribution.yaml"
    chmod 600 "$LLSD_DIR/llamastackdistribution.yaml"
    echo "        Saved to: $LLSD_DIR/llamastackdistribution.yaml"

    # 2. Check for ConfigMap with run.yaml/config.yaml
    echo "  [2/3] Checking for ConfigMap with run.yaml/config.yaml..."

    # Get configmap name from the LLSD spec if it exists
    CONFIGMAP_NAME=$(echo "$llsd" | jq -r '.spec.server.userConfig.configMapName // empty')

    if [ -n "$CONFIGMAP_NAME" ]; then
        echo "        Found ConfigMap: $CONFIGMAP_NAME"

        # Track this LLSD as having a custom config
        echo "$NAMESPACE/$NAME" >> "$CUSTOM_CONFIG_FILE"

        # Get the ConfigMap
        if oc get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" &>/dev/null; then
            oc get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o yaml > "$LLSD_DIR/configmap.yaml"
            chmod 600 "$LLSD_DIR/configmap.yaml"
            echo "        Saved ConfigMap to: $LLSD_DIR/configmap.yaml"

            # Extract run.yaml if it exists in the ConfigMap
            RUN_YAML=$(oc get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o jsonpath='{.data.run\.yaml}' 2>/dev/null || echo "")
            if [ -n "$RUN_YAML" ]; then
                echo "$RUN_YAML" > "$LLSD_DIR/run.yaml"
                chmod 600 "$LLSD_DIR/run.yaml"
                echo "        Extracted run.yaml to: $LLSD_DIR/run.yaml"
            fi

            # Extract config.yaml if it exists in the ConfigMap
            CONFIG_YAML=$(oc get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
            if [ -n "$CONFIG_YAML" ]; then
                echo "$CONFIG_YAML" > "$LLSD_DIR/config.yaml"
                chmod 600 "$LLSD_DIR/config.yaml"
                echo "        Extracted config.yaml to: $LLSD_DIR/config.yaml"
            fi
        else
            echo "        Warning: ConfigMap $CONFIGMAP_NAME not found"
        fi
    else
        echo "        No ConfigMap referenced (using default configuration)"
    fi

    # 3. Backup data from the pod
    echo "  [3/3] Backing up data from LlamaStack pod..."

    # Find the pod for this LLSD
    POD_NAME=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$POD_NAME" ]; then
        echo "        Found pod: $POD_NAME"

        # Save pod YAML
        echo "        Saving pod YAML..."
        oc get pod "$POD_NAME" -n "$NAMESPACE" -o yaml > "$LLSD_DIR/pod.yaml"
        chmod 600 "$LLSD_DIR/pod.yaml"
        echo "        Saved to: $LLSD_DIR/pod.yaml"

        # Find and save deployment YAML
        DEPLOYMENT_NAME=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="ReplicaSet")].name}' | sed 's/-[^-]*$//')
        if [ -n "$DEPLOYMENT_NAME" ]; then
            echo "        Saving deployment YAML..."
            oc get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o yaml > "$LLSD_DIR/deployment.yaml"
            chmod 600 "$LLSD_DIR/deployment.yaml"
            echo "        Saved to: $LLSD_DIR/deployment.yaml"
        fi

        # Check if the directory exists in the pod
        if oc exec -n "$NAMESPACE" "$POD_NAME" -- test -d /opt/app-root/src/.llama/distributions/rh 2>/dev/null; then
            echo "        Copying data from /opt/app-root/src/.llama/distributions/rh..."

            # Create local directory for pod data with restrictive permissions
            mkdir -p "$LLSD_DIR/pod-data"
            chmod 700 "$LLSD_DIR/pod-data"

            # Use oc rsync to copy the data
            if oc rsync -n "$NAMESPACE" "$POD_NAME:/opt/app-root/src/.llama/distributions/rh/" "$LLSD_DIR/pod-data/" --delete=false; then
                # Set restrictive permissions on all backed up files and directories
                find "$LLSD_DIR/pod-data" -type f -exec chmod 600 {} +
                find "$LLSD_DIR/pod-data" -type d -exec chmod 700 {} +
                echo "        Saved pod data to: $LLSD_DIR/pod-data/"

                # Show what was backed up
                FILE_COUNT=$(find "$LLSD_DIR/pod-data" -type f 2>/dev/null | wc -l)
                echo "        Backed up $FILE_COUNT file(s)"
            else
                echo "        Warning: Failed to copy data from pod"
            fi
        else
            echo "        Warning: Data directory not found in pod (may be empty or using different path)"
        fi
    else
        echo "        Warning: No running pod found for this LlamaStackDistribution"
        echo "        Skipping pod data backup"
    fi

    echo "  ✓ Completed backup for $NAME"
    echo ""
done

echo "=========================================="
echo "Backup Summary"
echo "=========================================="
echo "Backup location: $BACKUP_DIR"
echo ""

# Display warnings for LLSDs with custom configs
if [ -s "$CUSTOM_CONFIG_FILE" ]; then
    echo "=========================================="
    echo "⚠️  CUSTOM CONFIG WARNINGS"
    echo "=========================================="
    echo ""
    while IFS= read -r llsd_path; do
        echo "▸ $llsd_path"
        echo "  This distribution was using a custom config."
        echo "  State was backed up from the default location: /opt/app-root/src/.llama/distributions/rh"
        echo "  VERIFY in the config that this location was correct, as it may have been altered in the custom config."
        echo ""
    done < "$CUSTOM_CONFIG_FILE"
    echo "=========================================="
    echo ""
fi

echo "SECURITY NOTE:"
echo "Backup files may contain sensitive information (API tokens, passwords, etc.)"
echo "  - Keep backups secure and delete when no longer needed"
echo ""
echo "Next steps:"
echo "1. Review the archived configurations in: $BACKUP_DIR"
echo "2. Use archives as reference when creating your new LlamaStackDistribution in RHOAI 3.3.0"
echo "3. Update your client applications to use the new LlamaStack APIs"
