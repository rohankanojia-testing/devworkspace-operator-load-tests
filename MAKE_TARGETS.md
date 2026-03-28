# Makefile Targets Reference

## Available Make Targets

### 1. `test_load` - Controller Load Test

Tests the DevWorkspace controller's ability to create and manage multiple DevWorkspaces concurrently.

**Usage:**
```bash
make test_load ARGS="--max-devworkspaces 100 --max-vus 25"
```

**Common Arguments:**
- `--max-devworkspaces <N>` - Total workspaces to create
- `--max-vus <N>` - Max virtual users (concurrent operations)
- `--dwo-namespace <name>` - Operator namespace
- `--separate-namespaces <bool>` - Use separate namespace per workspace
- `--run-with-eclipse-che <bool>` - Run with Eclipse Che
- `--delete-devworkspace-after-ready <bool>` - Delete after ready

**Examples:**
```bash
# Basic test with 50 workspaces
make test_load ARGS="--max-devworkspaces 50"

# Test with Eclipse Che
make test_load ARGS="--max-devworkspaces 20 --run-with-eclipse-che true"

# Separate namespaces mode
make test_load ARGS="--max-devworkspaces 30 --separate-namespaces true"
```

### 2. `test_webhook_load` - Webhook Server Load Test

Tests webhook server admission control, identity immutability validation, and exec permission enforcement.

**Usage:**
```bash
make test_webhook_load ARGS="--users 50"
```

**Common Arguments:**
- `--users <N>` - Number of users to create
- `--dwo-namespace <name>` - Operator namespace

**Examples:**
```bash
# Test with 50 users
make test_webhook_load ARGS="--users 50"

# Custom operator namespace
make test_webhook_load ARGS="--users 30 --dwo-namespace my-operators"
```

### 3. `test_backup` - Backup Load Test (Correct Configuration)

Tests backup functionality with correct DWOC configuration. Creates workspaces, stops them, and monitors backup jobs.

**Usage:**
```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH=quay.io/your-registry \
  REGISTRY_SECRET=quay-push-secret
```

**Variables:**
| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_DEVWORKSPACES` | `15` | Number of workspaces to create |
| `BACKUP_MONITOR_DURATION` | `30` | Minutes to monitor backups |
| `LOAD_TEST_NAMESPACE` | `loadtest-devworkspaces` | Namespace for workspaces |
| `DWO_NAMESPACE` | `openshift-operators` | Operator namespace |
| `REGISTRY_PATH` | `quay.io/rokumar` | Container registry path |
| `REGISTRY_SECRET` | `quay-push-secret` | Registry secret name |

**Examples:**
```bash
# Quick test (5 workspaces, 10 min)
make test_backup \
  MAX_DEVWORKSPACES=5 \
  BACKUP_MONITOR_DURATION=10 \
  REGISTRY_PATH=quay.io/myregistry \
  REGISTRY_SECRET=my-secret

# Default test (15 workspaces, 30 min)
make test_backup \
  REGISTRY_PATH=quay.io/myregistry \
  REGISTRY_SECRET=my-secret

# Large test (100 workspaces, 60 min)
make test_backup \
  MAX_DEVWORKSPACES=100 \
  BACKUP_MONITOR_DURATION=60 \
  REGISTRY_PATH=quay.io/myregistry \
  REGISTRY_SECRET=my-secret
```

**What it does:**
1. ✅ Configures DWOC for backup (correct configuration)
2. ✅ Creates namespace
3. ✅ Creates N workspaces in parallel
4. ✅ Waits for 90% to become ready
5. ✅ Stops all workspaces
6. ✅ Monitors backup jobs
7. ✅ Collects metrics
8. ✅ Cleans up all resources

### 4. `test_backup_incorrect` - Backup Load Test (Incorrect Configuration)

Tests backup functionality with incorrect DWOC configuration to verify failure scenarios.

**Usage:**
```bash
make test_backup_incorrect \
  MAX_DEVWORKSPACES=10 \
  REGISTRY_PATH=quay.io/your-registry \
  REGISTRY_SECRET=quay-push-secret
```

**Variables:** Same as `test_backup`

**Examples:**
```bash
# Test failure scenario
make test_backup_incorrect \
  MAX_DEVWORKSPACES=10 \
  BACKUP_MONITOR_DURATION=15 \
  REGISTRY_PATH=quay.io/myregistry \
  REGISTRY_SECRET=my-secret
```

**What it does:**
Same as `test_backup` but configures DWOC with incorrect settings to test failure handling.

## Quick Reference

### Most Common Use Cases

**Run controller load test:**
```bash
make test_load ARGS="--max-devworkspaces 50"
```

**Run webhook load test:**
```bash
make test_webhook_load ARGS="--users 50"
```

**Run backup test (recommended):**
```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  REGISTRY_PATH=quay.io/your-registry \
  REGISTRY_SECRET=quay-push-secret
```

### Test Progression

Start small and scale up:

```bash
# 1. Small test to validate setup (5 workspaces)
make test_backup \
  MAX_DEVWORKSPACES=5 \
  BACKUP_MONITOR_DURATION=10 \
  REGISTRY_PATH=quay.io/your-registry \
  REGISTRY_SECRET=quay-push-secret

# 2. Medium test (15 workspaces) - default
make test_backup \
  REGISTRY_PATH=quay.io/your-registry \
  REGISTRY_SECRET=quay-push-secret

# 3. Large test (50 workspaces)
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH=quay.io/your-registry \
  REGISTRY_SECRET=quay-push-secret

# 4. Stress test (100+ workspaces)
make test_backup \
  MAX_DEVWORKSPACES=100 \
  BACKUP_MONITOR_DURATION=60 \
  REGISTRY_PATH=quay.io/your-registry \
  REGISTRY_SECRET=quay-push-secret
```

## Advanced Usage

### Using Direct Scripts Instead of Make

For advanced options not available via make targets (e.g., separate namespaces mode for backup test):

```bash
# Backup test with separate namespaces
./test-devworkspace-controller-load/backup/run-backup-load-test.sh \
  --max-devworkspaces 50 \
  --backup-monitor-duration 30 \
  --separate-namespaces true

# Controller load test with custom settings
./test-devworkspace-controller-load/runk6.sh \
  --max-devworkspaces 100 \
  --executor-mode ramping-vus \
  --test-duration-minutes 180
```

See individual test scripts for all available options.

## Notes

- **Backup tests** (`test_backup`, `test_backup_incorrect`) are fully self-contained - they create workspaces internally
- **Controller test** (`test_load`) can be used standalone
- **Webhook test** (`test_webhook_load`) requires user provisioning
- All tests generate HTML reports in the current directory
- Cleanup is handled automatically, but can be done manually if tests are interrupted

## See Also

- `BACKUP_TEST_GUIDE.md` - Detailed backup test guide
- `NAMESPACE_MODES.md` - Namespace mode documentation
- `IMPLEMENTATION_SUMMARY.md` - Technical implementation details
- `README.md` - Main project documentation
