# DevWorkspace Backup Load Tests

This directory contains load tests for DevWorkspace backup functionality, which allows workspaces to be backed up to a container registry when stopped.

## Overview

The backup load tests verify:
- Backup job creation when DevWorkspaces are stopped
- Backup success rate and reliability
- System performance during backup operations
- Operator and etcd resource usage
- **Restore verification**: Workspaces can be restored from backup images (optional)

## Test Modes

### Namespace Modes

- **Single Namespace** (`--separate-namespaces false`): All DevWorkspaces created in one namespace
- **Separate Namespaces** (`--separate-namespaces true`): Each DevWorkspace in its own namespace

### DWOC Configuration Modes

- **Correct Mode** (`correct`): DWOC properly configured with backup enabled, registry path, and auth secret (external registry like quay.io)
  - Pushes to external registry as OCI artifacts
  - Requires registry credentials (secret)
  - **k6 success criteria**: backup Job creation and Job completion (not ImageStreamTags)
  - Backup schedule: configurable (default: `*/10 * * * *` - every 10 minutes)

- **Incorrect Mode** (`incorrect`): DWOC misconfigured (for testing failure scenarios)
  - Intentionally broken registry path to test failure handling
  - Jobs will retry failed pods up to backOffLimit (typically 6 retries)
  - Test waits until jobs permanently fail or monitoring duration expires
  - Useful for testing operator behavior under failure conditions and retry logic
  - Backup schedule: configurable (default: `*/10 * * * *`)

- **OpenShift Internal Mode** (`openshift-internal`): DWOC configured to use OpenShift's internal image registry
  - Pushes to ImageStreamTags in the workspace namespace
  - **k6 success criteria**: `ImageStreamTag` `<workspace-name>:latest` per workspace (backup Jobs are not polled — they are ephemeral and misleading after TTL cleanup)
  - Uses service account token for authentication (no secret required)
  - Auto-detects the registry route or uses internal service
  - Includes `--insecure` flag for ORAS to handle self-signed certificates
  - Supports incorrect configuration by providing invalid registry path
  - Backup schedule: configurable (default: `*/10 * * * *`)

### Restore Verification

After successfully backing up workspaces, the test can optionally verify that workspaces can be restored from their backups. This is controlled by the `--verify-restore` flag (enabled by default).

**Restore Process:**
1. Deletes the original DevWorkspace
2. Recreates it with the `controller.devfile.io/restore-workspace: 'true'` attribute
3. Monitors the workspace until it reaches `Running` state
4. Measures restore duration and success rate

**Configuration:**
- `--verify-restore true|false` - Enable/disable restore verification (default: true)
- `--max-restore-samples N` - Maximum number of workspaces to restore (default: 10)

The restore verification uses a **sample** of backed up workspaces to keep test duration reasonable. By default, it restores up to 10 workspaces, but you can adjust this with `--max-restore-samples`.

**Important:** Restore verification is **automatically skipped** when:
- `DWOC_CONFIG_TYPE=incorrect` - Backups intentionally fail, so there are no valid images to restore
- `VERIFY_RESTORE=false` - Explicitly disabled
- No workspaces were successfully backed up

## Prerequisites

- Kubernetes cluster with DevWorkspace Operator installed
- **For external registry mode**: Container registry credentials (for pushing backup images)
- **For OpenShift internal mode**: OpenShift cluster with internal image registry enabled
- k6 load testing tool installed
- kubectl configured with cluster access

## Running Tests

Use the `make test_backup` target to run backup load tests. The test supports both single and separate namespace modes, and correct or incorrect DWOC configurations.

### Single Namespace + Correct DWOC Configuration (Default)

```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH=quay.io/your-username \
  REGISTRY_SECRET=your-registry-secret
```

### Separate Namespaces + Correct DWOC Configuration

```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH=quay.io/your-username \
  REGISTRY_SECRET=your-registry-secret \
  SEPARATE_NAMESPACE=true
```

### Single Namespace + Incorrect DWOC Configuration

For testing failure scenarios:

```bash
make test_backup \
  MAX_DEVWORKSPACES=20 \
  BACKUP_MONITOR_DURATION=15 \
  REGISTRY_PATH=quay.io/your-username \
  REGISTRY_SECRET=your-registry-secret \
  DWOC_CONFIG_TYPE=incorrect
```

### Separate Namespaces + Incorrect DWOC Configuration

```bash
make test_backup \
  MAX_DEVWORKSPACES=20 \
  BACKUP_MONITOR_DURATION=15 \
  REGISTRY_PATH=quay.io/your-username \
  REGISTRY_SECRET=your-registry-secret \
  DWOC_CONFIG_TYPE=incorrect \
  SEPARATE_NAMESPACE=true
```

### OpenShift Internal Registry (Auto-detect)

For OpenShift clusters, you can use the internal image registry with automatic route detection:

```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH="" \
  REGISTRY_SECRET="" \
  DWOC_CONFIG_TYPE=openshift-internal \
  SEPARATE_NAMESPACE=true
```

Or using the `backup.sh` wrapper:

```bash
./backup.sh 50 30 loadtest-devworkspaces openshift-operators "" "" openshift-internal true
```

### OpenShift Internal Registry (Custom Path)

If you need to specify a custom registry path (e.g., for CRC):

```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH=default-route-openshift-image-registry.apps-crc.testing \
  REGISTRY_SECRET="" \
  DWOC_CONFIG_TYPE=openshift-internal \
  SEPARATE_NAMESPACE=true
```

### OpenShift Internal Registry (Incorrect Configuration)

Test failure scenarios with OpenShift internal registry by providing an invalid registry path:

```bash
make test_backup \
  MAX_DEVWORKSPACES=20 \
  BACKUP_MONITOR_DURATION=15 \
  REGISTRY_PATH=non-existent-registry.openshift-image-registry.svc:9999 \
  REGISTRY_SECRET="" \
  DWOC_CONFIG_TYPE=openshift-internal \
  SEPARATE_NAMESPACE=true
```

### Backup Schedule (auto-scaled by default)

When `BACKUP_SCHEDULE` is unset or `auto`, the cron interval scales with workspace count:

| Workspaces | Schedule | Interval |
|------------|----------|----------|
| &lt; 1000 | `*/10 * * * *` | 10 minutes |
| 1000–2000 | `*/15 * * * *` | 15 minutes |
| &gt; 2000 | `*/25 * * * *` | 25 minutes |

Applied automatically by `backup-load-test.sh` and `run_all_backup_loadtests.sh`.

### Custom Backup Schedule

Control when backups run using a custom cron schedule:

```bash
# Run backups every 5 minutes
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_SCHEDULE="*/5 * * * *"

# Disable cron during test (use impossible date - Feb 31st never occurs)
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_SCHEDULE="0 0 31 2 *"

# Run backups every hour
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_SCHEDULE="0 * * * *"
```

### With Restore Verification (Default)

By default, restore verification is enabled and restores up to 10 workspaces:

```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH=quay.io/your-username \
  REGISTRY_SECRET=your-registry-secret
# VERIFY_RESTORE defaults to true, MAX_RESTORE_SAMPLES defaults to 10
```

### Restore All Backed Up Workspaces

To restore all backed up workspaces (instead of just a sample):

```bash
make test_backup \
  MAX_DEVWORKSPACES=20 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH=quay.io/your-username \
  REGISTRY_SECRET=your-registry-secret \
  MAX_RESTORE_SAMPLES=20
```

### Skip Restore Verification

To skip restore verification and only test backup:

```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH=quay.io/your-username \
  REGISTRY_SECRET=your-registry-secret \
  VERIFY_RESTORE=false
```

## Test Workflow

The complete backup load test (`backup-load-test.sh`) performs these phases:

1. **Phase 1: Configure DWOC for Backup**
   - Sets up registry credentials
   - Enables backup in DevWorkspaceOperatorConfig
   - Configures registry path and auth secret

2. **Phase 2: Create DevWorkspaces**
   - Creates specified number of DevWorkspaces
   - Waits for them to reach Ready state
   - Skips cleanup to leave workspaces for backup

3. **Phase 3: Backup Monitoring**
   - Stops all DevWorkspaces
   - Monitors backup job creation and completion
   - Tracks metrics (jobs, pods, success rate, resource usage)
   - Identifies successfully backed up workspaces

4. **Phase 4: Restore Verification** (optional, enabled by default)
   - Deletes a sample of backed up workspaces
   - Recreates them with restore attribute
   - Monitors restore process and measures success rate
   - Validates workspaces reach Running state

5. **Phase 5: Cleanup**
   - Removes backup jobs and restored workspaces
   - Deletes DevWorkspaces and namespaces
   - Resets DWOC configuration

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `MAX_DEVWORKSPACES` | Number of DevWorkspaces to create | `15` |
| `BACKUP_MONITOR_DURATION` | How long to monitor backups (minutes) | `30` |
| `LOAD_TEST_NAMESPACE` | Namespace for DevWorkspaces (single mode) | `loadtest-devworkspaces` |
| `DWO_NAMESPACE` | DevWorkspace Operator namespace | `openshift-operators` |
| `REGISTRY_PATH` | Container registry path for backups | `image-registry.openshift-image-registry.svc:5000` |
| `REGISTRY_SECRET` | Secret name for registry auth | `quay-push-secret` |
| `DWOC_CONFIG_TYPE` | DWOC config mode: `correct`, `incorrect`, or `openshift-internal` | `correct` |
| `SEPARATE_NAMESPACE` | Use separate namespaces per workspace | `false` |
| `BACKUP_SCHEDULE` | Cron schedule for backup jobs | auto: `*/10` (&lt;1000 ws), `*/15` (1000–2000), `*/25` (&gt;2000) |
| `VERIFY_RESTORE` | Enable restore verification after backup | `true` |
| `MAX_RESTORE_SAMPLES` | Maximum number of workspaces to restore for verification | `10` |

### Suite runner PV provisioning

When using `scripts/run_all_backup_loadtests.sh` with `PROVISION_PVS=true` (default on
non-CRC clusters), PV count is derived from the test plan plus restore headroom:

```
PV base = max_devworkspaces + PROVISION_PV_EXTRA
```

`PROVISION_PV_EXTRA` defaults to `MAX_RESTORE_SAMPLES` (or `10`) so parallel restore
samples can bind PVs while originals are still terminating. `provision-pvs.sh` applies
an additional 10% headroom on top.

```bash
# 30 workspaces → ~48 PVs (default extra 10)
PROVISION_PVS=true ./scripts/run_all_backup_loadtests.sh \
  test-plans/backup-restore-crc-openshift-internal-test-plan.json

# More headroom for slow PVC release at scale
PROVISION_PV_EXTRA=20 ./scripts/run_all_backup_loadtests.sh \
  test-plans/backup-restore-openshift-internal-test-plan.json
```

## Metrics Collected

The test collects comprehensive metrics:

### Backup Metrics

For **`openshift-internal`**, pass/fail uses **ImageStreamTag** metrics (`imagestreamtags_*`). CSV columns **Backup Attempted**, **Backup Succeeded**, and **Backup Failed** map from ImageStreamTag counts; **Backup Pods** and **Backup Job Duration** remain informational from ephemeral backup Jobs.

For **external registry** modes (`correct` / `incorrect`), Job metrics drive success detection.

- `backup_jobs_total` - Cumulative backup Jobs observed while monitoring (external registry modes only).
  **Can exceed workspace count** when the monitor window spans multiple DWOC backup cron cycles:
  each stopped workspace may receive one Job per cycle. Compare `backup_jobs_per_workspace` or
  workspace coverage instead of treating this as "jobs per workspace" when cron retries apply.
- `backup_pods_total` - Total backup pods created (external registry modes only)
- `backup_jobs_succeeded` - Successfully completed backup jobs (external registry modes only)
- `backup_jobs_failed` - Jobs that permanently failed (hit backOffLimit) (external registry modes only)
- `backup_jobs_running` - Currently running/pending backup jobs (external registry modes only)
- `backup_success_rate` - Percentage of successful backups
- `backup_job_duration` - Time taken for backup jobs to complete
- `workspaces_backed_up` - Number of workspaces successfully backed up
- `imagestreamtags_backed_up` - Workspaces with backup `ImageStreamTag` (openshift-internal only; updated during monitoring)
- `imagestreamtags_total` - Total workspaces expected to have a backup tag (openshift-internal only)
- `imagestreamtag_success_rate` - Ratio of workspaces with backup tags (openshift-internal only)
- `imagestreams_created` - Final ImageStreamTag count at verification (openshift-internal only; legacy CSV name)
- `imagestreams_expected` - Expected ImageStreamTag count (openshift-internal only; legacy CSV name)

### Restore Metrics
- `restore_workspaces_total` - Total restore attempts
- `restore_workspaces_succeeded` - Successfully restored workspaces
- `restore_workspaces_failed` - Failed restore attempts
- `restore_duration` - Time taken to restore and reach Running state
- `restore_success_rate` - Percentage of successful restores

### System Metrics
- `average_operator_cpu` - DWO CPU usage
- `average_operator_memory` - DWO memory usage
- `average_etcd_cpu` - etcd CPU usage
- `average_etcd_memory` - etcd memory usage
- `operator_cpu_violations` - Times operator exceeded CPU threshold
- `operator_mem_violations` - Times operator exceeded memory threshold
- `operator_pod_restarts_total` - Operator pod restart count
- `etcd_pod_restarts_total` - etcd pod restart count

## Output

After test completion, you'll find:
- `devworkspace-load-test-report.html` - DevWorkspace creation phase report
- `backup-load-test-report.html` - Backup monitoring phase report with all metrics

## Registry Secret Setup

Before running tests, create a registry push secret:

```bash
kubectl create secret docker-registry your-registry-secret \
  --docker-server=quay.io \
  --docker-username=your-username \
  --docker-password=your-password \
  -n openshift-operators

kubectl label secret your-registry-secret \
  controller.devfile.io/mount-to-devworkspace=true \
  controller.devfile.io/watch-secret=true \
  -n openshift-operators
```

## Troubleshooting

### No backup jobs created

- Verify DWOC backup configuration: `kubectl get dwoc devworkspace-operator-config -o yaml`
- Check that DevWorkspaces are stopped: `kubectl get dw -A`
- Ensure registry secret exists and has proper labels

**Only `openshift-internal` uses ImageStreamTag-based backup detection.** External modes (`correct`,
`incorrect`) continue to use backup Job status. For openshift-internal, verify with:

```bash
kubectl get imagestreamtags -A | grep loadtest
kubectl get imagestreamtag <workspace-name>:latest -n <workspace-namespace>
```

### `backup_jobs_total` much larger than workspace count

This is expected when Step 4 monitoring runs longer than one backup cron interval (`*/10`,
`*/15`, or `*/25` depending on scale). Stopped workspaces are eligible on every cron tick, so
each cycle can create a **new** Job per workspace. That inflates `backup_jobs_total` even though
each workspace only needed one terminal Job (pod retries inside a Job finish before the next cron).

**Incorrect-mode** tests stop once every workspace has a terminal Job (Failed after
`backOffLimit` or Succeeded). **Correct-mode** tests keep monitoring until all workspaces are
backed up or the configured `--backup-wait-minutes` expires.

### Backup jobs failing

- Check job logs: `kubectl logs job/devworkspace-backup-xxxxx`
- Verify registry credentials are correct
- Ensure registry path is accessible and writable

### Metrics not collected

- Ensure operator pod is running: `kubectl get pods -n openshift-operators`
- Check etcd namespace matches your cluster (OpenShift vs vanilla K8s)
- Verify RBAC permissions for k6-backup-tester ServiceAccount

## DevWorkspace template for backup tests

Backup tests require **per-workspace persistent storage** (not ephemeral). The default template is
[`dw-minimal-per-workspace-storage-scale.json`](https://gist.githubusercontent.com/rohanKanojia/fb759dca630fe605880847a54d1e141c/raw/da20c8c01e40cb7cb9ecea65dd8ff3758c0b5f7a/dw-minimal-per-workspace-storage-scale.json)
(copied in-repo at `dw-minimal-per-workspace-storage-scale.json`).

| | Legacy gist template | Scale-optimized (default) | Controller load test (`dw-minimal.json`) |
|--|---------------------|---------------------------|------------------------------------------|
| Storage | per-workspace PVC | per-workspace PVC | ephemeral |
| CPU request | 100m | **10m** | 10m |
| Memory request | 256Mi | **64Mi** | 16Mi |
| Git project | hello-world | hello-world | none |
| CPU @ 2500 ws | ~250 cores requested | **~25 cores requested** | ~25 cores requested |

At 2500 workspaces on a 4-node perflab cluster, the legacy **100m CPU** template leaves ~4 pods
unschedulable (`Insufficient cpu`). The scale template matches controller-test CPU requests while
keeping PVC + git content for backup/restore sampling.

Override the template:

```bash
BACKUP_DEVWORKSPACE_TEMPLATE=/path/to/custom.json make test_backup ARGS="..."
```

Or pass `--devworkspace-link` through `runk6.sh` (supports `https://` URLs or a repo-relative file path).

**Smoke-test** after changing the template: run 250 → 500 → 2500 and confirm restore samples (10
workspaces) still reach Running with project files present.

## Notes

- In **separate namespaces mode**, each DevWorkspace gets its own namespace (e.g., `dw-test-1-namespace`)
- Backup jobs are created in the same namespace as their DevWorkspace
- Metrics are collected **cluster-wide** using label selectors, so they work across all namespaces
- The **incorrect DWOC mode** is useful for testing failure scenarios and error handling
