#!/bin/bash
set -euo pipefail

# --- CONFIG ---
BASE_DIR="/var/lib/hostpath-provisioner"
STORAGE_CLASS="hostpath-sc"
PV_SIZE="200Mi"
PV_PER_NODE=750

WORKLOAD_LABEL="devworkspace-load-test"
TEST_ID="run-$(date +%s)"   # dynamic per run

MAX_WORKSPACES="${1:-0}"
if [ "$MAX_WORKSPACES" -eq 0 ]; then
  echo "Usage: $0 <max_workspaces>"
  exit 1
fi

echo "========================================="
echo "🚀 DevWorkspace PV Provisioner"
echo "========================================="
echo "Max Workspaces: $MAX_WORKSPACES"
echo "Test ID: $TEST_ID"
echo "========================================="

# --- CLEANUP OLD PVs ---
echo "🧹 Cleaning old test PVs (workload=$WORKLOAD_LABEL)..."

# Delete PVCs first (avoid PV stuck in Bound/Released)
oc delete pvc -A -l workload=$WORKLOAD_LABEL --ignore-not-found || true

# Delete PVs by label
oc delete pv -l workload=$WORKLOAD_LABEL --ignore-not-found || true

echo "✅ Old test PVs cleaned"
echo ""

# --- NODES ---
NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
NODE_COUNT=$(echo "$NODES" | wc -w)

TOTAL_PVS_NEEDED=$(( MAX_WORKSPACES + (MAX_WORKSPACES / 10) ))
PVS_PER_NODE=$(( (TOTAL_PVS_NEEDED + NODE_COUNT - 1) / NODE_COUNT ))

echo "Nodes: $NODE_COUNT | PVs per node: $PVS_PER_NODE"

# --- STEP 1: Prepare directories ---
for NODE in $NODES; do
  echo "🔧 Preparing $NODE"

  oc debug node/$NODE -- chroot /host bash -c "
    mkdir -p $BASE_DIR/$NODE

    for i in \$(seq 1 $PVS_PER_NODE); do
      mkdir -p $BASE_DIR/$NODE/pv-\$i
    done

    chmod -R 777 $BASE_DIR
    chcon -R -t container_file_t $BASE_DIR || true
  " >/dev/null 2>&1

  COUNT=$(oc debug node/$NODE -- chroot /host bash -c \
    "find $BASE_DIR/$NODE -maxdepth 1 -type d -name 'pv-*' | wc -l")

  if [ "$COUNT" -lt "$PVS_PER_NODE" ]; then
    echo "❌ Directory creation failed on $NODE ($COUNT/$PVS_PER_NODE)"
    exit 1
  fi

  echo "✅ $NODE ready ($COUNT dirs)"
done

# --- STEP 2: StorageClass ---
cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $STORAGE_CLASS
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF

echo "✅ StorageClass ready"

# --- STEP 3: PV creation ---
echo "📦 Creating PVs..."

for NODE in $NODES; do
  for i in $(seq 1 $PVS_PER_NODE); do
    cat <<EOF | oc apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolume
metadata:
  name: hp-pv-${NODE}-${i}
  labels:
    workload: ${WORKLOAD_LABEL}
    test-id: ${TEST_ID}
    type: hostpath
spec:
  capacity:
    storage: ${PV_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: ${STORAGE_CLASS}
  hostPath:
    path: ${BASE_DIR}/${NODE}/pv-${i}
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - ${NODE}
EOF
  done

  echo "✅ PVs created for $NODE"
done

echo ""
echo "========================================="
echo "🎉 DONE"
echo "========================================="
echo "Test ID: $TEST_ID"
echo "Delete later with:"
echo "  oc delete pv -l workload=$WORKLOAD_LABEL"
echo "========================================="