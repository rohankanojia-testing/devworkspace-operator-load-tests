#!/usr/bin/env bash
# Default DevWorkspace templates for backup load tests.
# Sourced by backup-load-test.sh and run_all_backup_loadtests.sh.

BACKUP_DEFAULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_REPO_ROOT="$(cd "${BACKUP_DEFAULTS_DIR}/../.." && pwd)"

# Git-backed scale template (default): DWOC projectClone tuning lowers init CPU from 100m to 10m.
BACKUP_DEVWORKSPACE_TEMPLATE_DEFAULT="${BACKUP_REPO_ROOT}/common/templates/dw-minimal-per-workspace-storage-scale.json"

# PostStart scale template: no project-clone init; seeds /projects via lifecycle hook.
BACKUP_DEVWORKSPACE_TEMPLATE_POSTSTART="${BACKUP_REPO_ROOT}/common/templates/dw-minimal-per-workspace-storage-scale-poststart.json"

# Alias for explicit git template selection.
BACKUP_DEVWORKSPACE_TEMPLATE_GIT="${BACKUP_DEVWORKSPACE_TEMPLATE_DEFAULT}"

resolve_backup_devworkspace_template() {
  local requested="${1:-}"
  if [[ -n "${requested}" ]]; then
    echo "${requested}"
    return 0
  fi
  echo "${BACKUP_DEVWORKSPACE_TEMPLATE_DEFAULT}"
}
