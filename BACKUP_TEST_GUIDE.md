# Backup Load Test - Quick Start Guide

## Prerequisites

1. ✅ Kubernetes/OpenShift cluster access
2. ✅ **Logged into the cluster** (run `kubectl get nodes` to verify)
3. ✅ **Permissions to create secrets** in the operator namespace (usually requires cluster-admin)
4. ✅ `kubectl` installed (>= 1.24.0)
5. ✅ `k6` installed (>= 1.1.0)
6. ✅ **Container registry credentials** (REGISTRY_USERNAME and REGISTRY_PASSWORD)

### Creating the Registry Secret

The backup test requires a container registry secret to push workspace backups. The secret is created automatically in the **DevWorkspace Operator namespace** (typically `openshift-operators`) if you provide credentials via environment variables.

#### Option 1: Automatic Creation (Recommended)

Set environment variables and the test will create the secret automatically:

```bash
export REGISTRY_USERNAME=<your-username>
export REGISTRY_PASSWORD=<your-password>

make test_backup \
  REGISTRY_PATH=quay.io/your-registry \
  REGISTRY_SECRET=quay-push-secret
```

#### Option 2: Manual Creation

If you prefer to create the secret manually:

```bash
# Create from credentials
kubectl create secret docker-registry quay-push-secret \
  --docker-server=quay.io \
  --docker-username=<your-username> \
  --docker-password=<your-password> \
  -n openshift-operators

# Or copy from existing namespace
kubectl get secret quay-push-secret -n <source-namespace> -o yaml | \
  sed 's/namespace: .*/namespace: openshift-operators/' | \
  kubectl apply -f -
```

**Important:** The secret **must exist in the operator namespace** (not the load test namespace) because the DevWorkspace Operator uses it to create backup jobs.

## Running the Test

### Option 1: Make Target (Recommended)

The easiest way to run the backup load test:

```bash
make test_backup \
  REGISTRY_PATH=quay.io/your-registry \
  REGISTRY_SECRET=quay-push-secret
```

#### Available Make Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_DEVWORKSPACES` | `15` | Number of workspaces to create |
| `BACKUP_MONITOR_DURATION` | `30` | Minutes to monitor backups |
| `LOAD_TEST_NAMESPACE` | `loadtest-devworkspaces` | Namespace for workspaces |
| `DWO_NAMESPACE` | `openshift-operators` | DevWorkspace Operator namespace |
| `REGISTRY_PATH` | `quay.io/rokumar` | Container registry path |
| `REGISTRY_SECRET` | `quay-push-secret` | Registry secret name (must exist in `DWO_NAMESPACE`) |

#### Examples

**Small test (5 workspaces, 10 minutes):**
```bash
make test_backup \
  MAX_DEVWORKSPACES=5 \
  BACKUP_MONITOR_DURATION=10 \
  REGISTRY_PATH=quay.io/your-registry \
  REGISTRY_SECRET=quay-push-secret
```

**Large test (100 workspaces, 60 minutes):**
```bash
make test_backup \
  MAX_DEVWORKSPACES=100 \
  BACKUP_MONITOR_DURATION=60 \
  REGISTRY_PATH=quay.io/your-registry \
  REGISTRY_SECRET=quay-push-secret
```

**Test failure scenario (incorrect DWOC config):**
```bash
make test_backup_incorrect \
  MAX_DEVWORKSPACES=10 \
  REGISTRY_PATH=quay.io/your-registry \
  REGISTRY_SECRET=quay-push-secret
```

### Option 2: Direct Script (Advanced)

For advanced options like separate namespaces mode:

```bash
./test-devworkspace-controller-load/backup/run-backup-load-test.sh \
  --max-devworkspaces 50 \
  --backup-monitor-duration 30 \
  --namespace loadtest-devworkspaces \
  --dwo-namespace openshift-operators \
  --separate-namespaces false
```

#### Script Options

| Option | Default | Description |
|--------|---------|-------------|
| `--max-devworkspaces <N>` | `50` | Number of workspaces to create |
| `--backup-monitor-duration <M>` | `30` | Minutes to monitor backups |
| `--namespace <name>` | `loadtest-devworkspaces` | Namespace for workspaces |
| `--dwo-namespace <name>` | `openshift-operators` | Operator namespace |
| `--separate-namespaces <bool>` | `false` | Use separate namespace per workspace |
| `--devworkspace-link <url>` | (per-workspace-storage gist) | DevWorkspace template URL |
| `--devworkspace-ready-timeout <S>` | `600` | Seconds to wait for ready state |

#### Advanced Examples

**Separate namespaces mode:**
```bash
./test-devworkspace-controller-load/backup/run-backup-load-test.sh \
  --max-devworkspaces 20 \
  --backup-monitor-duration 30 \
  --separate-namespaces true
```

**Custom workspace template:**
```bash
./test-devworkspace-controller-load/backup/run-backup-load-test.sh \
  --max-devworkspaces 50 \
  --devworkspace-link "https://your-custom-template.json"
```

**Longer timeout for slow clusters:**
```bash
./test-devworkspace-controller-load/backup/run-backup-load-test.sh \
  --max-devworkspaces 50 \
  --devworkspace-ready-timeout 1200
```

## What Happens During the Test

### Phase 1: DWOC Configuration
- Configures DevWorkspace Operator for backup
- Sets registry credentials
- Enables backup cron jobs

### Phase 2: Namespace Creation
- Creates namespace(s) for workspaces
- Single mode: 1 namespace
- Separate mode: N namespaces (one per workspace)

### Phase 3: Workspace Creation & Backup Monitoring

**Step 1: Create All Workspaces (Parallel)**
```
Creating 50 DevWorkspaces...
Namespace mode: single namespace
Created 50 workspaces
```

**Step 2: Wait for Ready State (Batch Polling)**
```
Waiting for workspaces to become ready...
  ✅ loadtest-devworkspaces/dw-test-1-0 ready in 45.2s
  ✅ loadtest-devworkspaces/dw-test-1-1 ready in 47.8s
  [100s] Ready: 15, Failed: 0, Creating: 35
  [200s] Ready: 38, Failed: 1, Creating: 11
✅ Reached target: 45/50 (90.0%) workspaces ready
```

**Step 3: Stop Workspaces & Monitor Backups**
```
Stopping all DevWorkspaces...
Waiting for backup Jobs to be created...
Monitoring backup Jobs and system metrics...
```

### Phase 4: Cleanup
- Deletes all DevWorkspaces
- Deletes all backup Jobs
- Deletes namespace(s)
- Resets DWOC configuration
- Cleans up RBAC resources

## Output & Reports

### Console Output
Real-time progress with:
- Workspace creation status
- Ready/failed counts
- Backup job progress
- System metrics (operator/etcd CPU/memory)

### HTML Report
Generated at: `backup-load-test-report.html`

Includes:
- ✅ Setup metrics (workspaces created, ready, failed, duration)
- ✅ Backup metrics (jobs succeeded, failed, duration)
- ✅ System metrics (CPU, memory, pod restarts)
- ✅ Success rates and thresholds

## Success Criteria

The test passes if:
- ✅ At least 90% of workspaces reach ready state
- ✅ All ready workspaces are stopped successfully
- ✅ Backup jobs created for all stopped workspaces
- ✅ Backup success rate >= 95%
- ✅ No operator CPU/memory violations
- ✅ No operator/etcd pod restarts

## Troubleshooting

### No workspaces created
- **Check:** RBAC permissions for creating namespaces/devworkspaces
- **Fix:** Review ServiceAccount and ClusterRole permissions

### Workspaces fail to become ready
- **Check:** DevWorkspace Operator logs
- **Fix:** Increase `--devworkspace-ready-timeout` for slow clusters

### Backup jobs don't start
- **Check:** DWOC configuration (`kubectl get dwoc -o yaml`)
- **Fix:** Verify registry credentials and backup configuration

### Test timeout
- **Check:** Cluster resources and workspace count
- **Fix:** Reduce `MAX_DEVWORKSPACES` or increase `BACKUP_MONITOR_DURATION`

### Cleanup fails
- **Check:** Namespace finalizers
- **Fix:** Manually delete stuck resources: `kubectl delete dw --all -n <namespace> --force --grace-period=0`

## Verification Commands

### Check workspaces created
```bash
# Single namespace mode
kubectl get dw -n loadtest-devworkspaces

# Separate namespaces mode
kubectl get dw --all-namespaces -l load-test=test-type
```

### Check backup jobs
```bash
kubectl get jobs -A -l controller.devfile.io/backup-job=true
```

### Check operator metrics
```bash
kubectl top pods -n openshift-operators -l app.kubernetes.io/name=devworkspace-controller
```

### View test report
```bash
open backup-load-test-report.html
```

## Tips

1. **Start small:** Test with 5-10 workspaces first to validate setup
2. **Monitor resources:** Watch cluster CPU/memory during test
3. **Adjust timeouts:** Slow clusters may need longer `--devworkspace-ready-timeout`
4. **Clean up manually:** If test is interrupted, clean up: `make test_backup` will clean up at start
5. **Check logs:** Operator logs can help debug workspace failures

## Next Steps

After successful test:
- Review HTML report for metrics
- Check backup job status
- Verify workspace cleanup
- Scale up for larger tests

Need help? See:
- `NAMESPACE_MODES.md` - Detailed namespace mode documentation
- `IMPLEMENTATION_SUMMARY.md` - Technical implementation details
- `CLAUDE.md` - Project guidelines and conventions
