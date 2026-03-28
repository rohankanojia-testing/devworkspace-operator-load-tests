# Backup Load Test - Namespace Modes

## Overview

The backup load test supports two namespace modes for creating DevWorkspaces:

1. **Single Namespace Mode** - All workspaces in one namespace
2. **Separate Namespaces Mode** - Each workspace in its own namespace

## Single Namespace Mode (Default)

### Configuration
```bash
SEPARATE_NAMESPACES=false  # or omit (default)
```

### Behavior
- ✅ All DevWorkspaces created in a single namespace
- ✅ Namespace name: `${LOAD_TEST_NAMESPACE}` (e.g., `loadtest-devworkspaces`)
- ✅ Easier cleanup - delete one namespace
- ✅ Lower resource overhead

### Example Commands

**Using Make (Recommended):**
```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30
```

**Using Script Directly:**
```bash
./test-devworkspace-controller-load/backup/run-backup-load-test.sh \
  --max-devworkspaces 50 \
  --backup-monitor-duration 30 \
  --separate-namespaces false
```

### Workspace Layout
```
Namespace: loadtest-devworkspaces
├── dw-test-1-0
├── dw-test-1-1
├── dw-test-1-2
├── ...
└── dw-test-1-49
```

### Use Cases
- ✅ Standard load testing
- ✅ Most backup scenarios
- ✅ When namespace quotas are not a concern
- ✅ Faster cleanup

## Separate Namespaces Mode

### Configuration
```bash
SEPARATE_NAMESPACES=true
```

### Behavior
- ✅ Each DevWorkspace gets its own namespace
- ✅ Namespace pattern: `${LOAD_TEST_NAMESPACE}-${index}` (e.g., `loadtest-devworkspaces-0`)
- ✅ Better isolation between workspaces
- ✅ Tests namespace-level operations

### Example Commands

**Using Script (separate namespaces not available via make):**
```bash
./test-devworkspace-controller-load/backup/run-backup-load-test.sh \
  --max-devworkspaces 50 \
  --backup-monitor-duration 30 \
  --separate-namespaces true
```

> **Note:** The `make test_backup` target always uses single namespace mode. For separate namespaces, use the script directly.

### Workspace Layout
```
Namespace: loadtest-devworkspaces-0
└── dw-test-1-0

Namespace: loadtest-devworkspaces-1
└── dw-test-1-1

Namespace: loadtest-devworkspaces-2
└── dw-test-1-2

...

Namespace: loadtest-devworkspaces-49
└── dw-test-1-49
```

### Use Cases
- ✅ Testing namespace isolation
- ✅ Simulating multi-tenant scenarios
- ✅ Testing backup across namespaces
- ✅ When namespace-level RBAC testing is needed

## Implementation Details

### Workspace Creation Flow

**Single Namespace Mode:**
```
1. Create namespace: loadtest-devworkspaces
2. Create all workspaces in parallel
3. Poll all workspaces until ready
```

**Separate Namespaces Mode:**
```
1. For each workspace:
   a. Create namespace: loadtest-devworkspaces-${i}
   b. Create workspace in that namespace
2. Poll all workspaces until ready
```

### Cleanup

**Single Namespace Mode:**
- Delete all DevWorkspaces
- Delete backup Jobs
- Delete single namespace

**Separate Namespaces Mode:**
- Delete all DevWorkspaces (across namespaces)
- Delete backup Jobs (across namespaces)
- Delete all namespaces matching pattern

## RBAC Requirements

Both modes require:
- `create`, `delete` permissions on namespaces
- `create`, `delete`, `deletecollection` permissions on devworkspaces
- `list`, `get`, `watch` permissions on pods, jobs, metrics

## Performance Considerations

**Single Namespace Mode:**
- ⚡ Faster namespace creation (one namespace)
- 🔄 Easier to query all workspaces (single namespace)
- 📊 Simpler metrics collection
- 🧹 Faster cleanup

**Separate Namespaces Mode:**
- 🐢 Slower namespace creation (N namespaces)
- 🔍 Must query across namespaces
- 📊 More complex metrics aggregation
- 🧹 Slower cleanup (N namespaces)

## Verification

### Check Current Mode
```bash
# During test execution, check console output:
Namespace mode: single namespace
# or
Namespace mode: separate namespaces
```

### Verify Namespaces Created

**Single Namespace:**
```bash
kubectl get namespace loadtest-devworkspaces
```

**Separate Namespaces:**
```bash
kubectl get namespaces | grep loadtest-devworkspaces
# Should show: loadtest-devworkspaces-0, loadtest-devworkspaces-1, etc.
```

### Verify Workspaces

**Single Namespace:**
```bash
kubectl get dw -n loadtest-devworkspaces
```

**Separate Namespaces:**
```bash
kubectl get dw --all-namespaces -l load-test=test-type
```

## Switching Between Modes

Simply change the `--separate-namespaces` flag:

```bash
# Switch to single namespace
--separate-namespaces false

# Switch to separate namespaces
--separate-namespaces true
```

No code changes required - the test automatically handles both modes!

## Troubleshooting

### Single Namespace Mode Issues

**Problem:** Namespace already exists
- **Solution:** Delete existing namespace or use different name

**Problem:** Too many workspaces in one namespace
- **Solution:** Consider separate namespaces mode for large tests

### Separate Namespaces Mode Issues

**Problem:** Namespace creation fails
- **Solution:** Check RBAC permissions for namespace creation

**Problem:** Slow namespace creation
- **Solution:** This is expected with many namespaces; consider smaller batch sizes

**Problem:** Cleanup takes long time
- **Solution:** Namespaces delete asynchronously; this is normal behavior
