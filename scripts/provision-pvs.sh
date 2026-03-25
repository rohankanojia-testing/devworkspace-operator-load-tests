#!/bin/bash
# 🚀 HIGH-DENSITY STATIC PV PROVISIONER FOR BACKUP LOAD TESTS
# Provisions PVs on bare metal nodes for large-scale DevWorkspace testing

set -euo pipefail

# --- CONFIGURATION ---
BASE_DIR="${PV_BASE_DIR:-/tmp/hostpath-storage}"
STORAGE_CLASS="${PV_STORAGE_CLASS:-hostpath-sc}"
PV_SIZE="${PV_SIZE:-50Mi}"  # Minimal size for backup testing
PV_PER_NODE="${PV_PER_NODE:-800}"
PV_LABEL="${PV_LABEL:-load-test}"
NAMESPACE="${NAMESPACE:-test-rokum}"

# Parse arguments
MAX_WORKSPACES="${1:-0}"

if [ "$MAX_WORKSPACES" -eq 0 ]; then
    echo "ERROR: Maximum number of workspaces required"
    echo "Usage: $0 <max_workspaces>"
    echo "Example: $0 2500"
    exit 1
fi

echo "========================================="
echo "PV Provisioner for Backup Load Tests"
echo "========================================="
echo "Max Workspaces: $MAX_WORKSPACES"
echo "PV Size: $PV_SIZE"
echo "Storage Class: $STORAGE_CLASS"
echo "PVs per Node: $PV_PER_NODE"
echo "========================================="
echo ""

# Get worker nodes automatically
NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
NODE_COUNT=$(echo "$NODES" | wc -w)

if [ "$NODE_COUNT" -eq 0 ]; then
    echo "❌ ERROR: No nodes found"
    exit 1
fi

echo "Found $NODE_COUNT nodes"

# Calculate PVs needed per node (add 10% buffer)
TOTAL_PVS_NEEDED=$(( MAX_WORKSPACES + (MAX_WORKSPACES / 10) ))
PVS_PER_NODE_CALC=$(( (TOTAL_PVS_NEEDED + NODE_COUNT - 1) / NODE_COUNT ))

# Cap at PV_PER_NODE limit
if [ "$PVS_PER_NODE_CALC" -gt "$PV_PER_NODE" ]; then
    PVS_PER_NODE_CALC=$PV_PER_NODE
    echo "⚠️  Warning: Capping PVs per node at $PV_PER_NODE"
fi

TOTAL_PVS=$((PVS_PER_NODE_CALC * NODE_COUNT))

echo "Provisioning $PVS_PER_NODE_CALC PVs per node"
echo "Total PVs to create: $TOTAL_PVS"
echo ""

# Step 1: Adjust Namespace Security (SCC) for OpenShift
echo "🔐 Step 1: Adjusting Namespace Security (SCC)..."
if command -v oc &> /dev/null; then
    oc adm policy add-scc-to-group hostmount-anyuid system:serviceaccounts:$NAMESPACE 2>/dev/null || true
    oc adm policy add-scc-to-group privileged system:serviceaccounts:$NAMESPACE 2>/dev/null || true
    echo "✅ SCC policies configured"
else
    echo "ℹ️  Not an OpenShift cluster, skipping SCC configuration"
fi
echo ""

# Step 2: Pre-create and unlock directories on nodes
echo "🏗️  Step 2: Preparing directories on nodes..."
for NODE in $NODES; do
    echo "  🔓 Creating $PVS_PER_NODE_CALC directories on $NODE..."
    kubectl debug node/$NODE -- chroot /host /bin/bash -c "
        mkdir -p $BASE_DIR/$NODE/pv-{1..$PVS_PER_NODE_CALC} && \
        chmod -R 777 $BASE_DIR && \
        chcon -R -t container_file_t $BASE_DIR 2>/dev/null || true" 2>&1 | grep -v "Temporary namespace" || true
done
echo "✅ Directories prepared on all nodes"
echo ""

# Step 3: Configure StorageClass
echo "🛠️  Step 3: Configuring StorageClass..."
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF
echo "✅ StorageClass ${STORAGE_CLASS} configured"
echo ""

# Step 4: Create PersistentVolumes
echo "📡 Step 4: Creating $TOTAL_PVS PersistentVolumes..."
PV_COUNT=0

for NODE in $NODES; do
    echo "  📦 Generating PV manifest for $NODE..."
    MANIFEST_FILE="/tmp/pvs-${NODE}.yaml"
    > "$MANIFEST_FILE"

    for i in $(seq 1 $PVS_PER_NODE_CALC); do
        PV_NAME="hp-pv-${NODE}-${i}"
        NODE_DIR="${BASE_DIR}/${NODE}/pv-${i}"

        cat <<EOF >> "$MANIFEST_FILE"
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
  labels:
    ${PV_LABEL}: "backup-run"
spec:
  capacity:
    storage: ${PV_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: ${STORAGE_CLASS}
  hostPath:
    path: ${NODE_DIR}
    type: Directory
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${NODE}
---
EOF
        PV_COUNT=$((PV_COUNT + 1))
    done

    kubectl apply -f "$MANIFEST_FILE" >/dev/null 2>&1
    rm "$MANIFEST_FILE"
    echo "  ✅ Created $PVS_PER_NODE_CALC PVs on $NODE"
done

echo ""
echo "========================================="
echo "🏁 SUCCESS: Cluster PV Provisioning Complete"
echo "========================================="
echo "Total PVs Created: $PV_COUNT"
echo "PV Size: $PV_SIZE"
echo "Storage Class: $STORAGE_CLASS"
echo "Ready for ${MAX_WORKSPACES}+ workspace backup testing"
echo "========================================="
