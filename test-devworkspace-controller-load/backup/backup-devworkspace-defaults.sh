#!/usr/bin/env bash
# Default DevWorkspace templates for backup load tests.
# Sourced by backup-load-test.sh and run_all_backup_loadtests.sh.

BACKUP_DEFAULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_REPO_ROOT="$(cd "${BACKUP_DEFAULTS_DIR}/../.." && pwd)"

# Scale-optimized: no git (no project-clone init), PVC at /projects, postStart seeds backup content.
BACKUP_DEVWORKSPACE_TEMPLATE_DEFAULT="${BACKUP_REPO_ROOT}/test-devworkspace-controller-load/backup/dw-minimal-per-workspace-storage-scale-poststart.json"

# Git-backed scale template (100m project-clone CPU); use for comparison or if postStart is unsuitable.
BACKUP_DEVWORKSPACE_TEMPLATE_GIT="${BACKUP_REPO_ROOT}/test-devworkspace-controller-load/backup/dw-minimal-per-workspace-storage-scale.json"

resolve_backup_devworkspace_template() {
  local requested="${1:-}"
  if [[ -n "${requested}" ]]; then
    echo "${requested}"
    return 0
  fi
  echo "${BACKUP_DEVWORKSPACE_TEMPLATE_DEFAULT}"
}
