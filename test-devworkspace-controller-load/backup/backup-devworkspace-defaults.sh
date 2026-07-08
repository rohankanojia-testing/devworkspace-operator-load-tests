#!/usr/bin/env bash
# Default DevWorkspace template for all backup load tests.
BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# No-git scale template: per-workspace PVC without project-clone init (10m CPU vs 100m with git).
BACKUP_DEVWORKSPACE_TEMPLATE="${BACKUP_DEVWORKSPACE_TEMPLATE:-${BACKUP_DIR}/dw-minimal-per-workspace-storage-scale-no-git.json}"
export BACKUP_DEVWORKSPACE_TEMPLATE
