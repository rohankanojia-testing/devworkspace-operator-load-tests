---
name: run-loadtest
description: Run and monitor DevWorkspace load tests on remote performance lab cluster.
allowed-tools: Bash, AskUserQuestion, Read
---

Execute DevWorkspace Operator load tests on the remote performance lab cluster via SSH.

## Prerequisites

Environment variables required:
- `$PERFLAB_USER` - SSH username for performance lab
- `$PERFLAB_HOST` - SSH hostname for performance lab

## Execution Steps

### 1. Verify Environment Variables

Check that `PERFLAB_USER` and `PERFLAB_HOST` are set:

```bash
if [[ -z "$PERFLAB_USER" || -z "$PERFLAB_HOST" ]]; then
  echo "Error: PERFLAB_USER and PERFLAB_HOST environment variables must be set"
  exit 1
fi
```

### 2. Check DevWorkspace Operator Installation

SSH into the cluster and verify the operator is installed:

```bash
ssh "$PERFLAB_USER@$PERFLAB_HOST" "kubectl get deployment -n openshift-operators devworkspace-controller-manager"
```

If not found, inform user that DevWorkspace Operator must be installed first.

### 3. Check DevWorkspaceOperatorConfig

Verify the required configuration exists with proper settings to avoid flakes:

```bash
ssh "$PERFLAB_USER@$PERFLAB_HOST" "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators -o yaml"
```

The config should have:
```yaml
apiVersion: controller.devfile.io/v1alpha1
config:
  workspace:
    # To avoid intermittent image pull failures
    imagePullPolicy: IfNotPresent
    # To avoid ready timeout errors
    progressTimeout: 3600s
kind: DevWorkspaceOperatorConfig
metadata:
  name: devworkspace-operator-config
  namespace: openshift-operators
```

If missing or incorrect:
- Inform the user about the required configuration
- Ask if they want to apply it
- If yes, create and apply the config

### 4. Verify Load Test Repository

Check if the repository is cloned at `/home/devworkspace-operator-load-tests`:

```bash
ssh "$PERFLAB_USER@$PERFLAB_HOST" "test -d /home/devworkspace-operator-load-tests && echo 'EXISTS' || echo 'MISSING'"
```

If missing, inform user and ask if they want to clone it:
```bash
ssh "$PERFLAB_USER@$PERFLAB_HOST" "cd /home && git clone https://github.com/devfile/devworkspace-operator-load-tests.git"
```

### 5. Prompt User for Test Type

Use `AskUserQuestion` to ask which type of load test to run:

**Options:**
1. **Controller Load Tests** - Test DevWorkspace controller's ability to create and manage DevWorkspaces
2. **Webhook Load Tests** - Test webhook server admission control and validation
3. **Backup Load Tests** - Test backup and restore functionality

### 6. Execute Appropriate Test Script

Based on user selection, run the corresponding script:

#### Controller Load Tests
```bash
ssh "$PERFLAB_USER@$PERFLAB_HOST" "cd /home/devworkspace-operator-load-tests && ./scripts/run_all_loadtests.sh test-plans/controller-test-plan.json"
```

#### Webhook Load Tests
```bash
ssh "$PERFLAB_USER@$PERFLAB_HOST" "cd /home/devworkspace-operator-load-tests && ./scripts/run_all_webhook_loadtests.sh test-plans/webhook-performancelabs-test-plan.json"
```

#### Backup Load Tests
```bash
ssh "$PERFLAB_USER@$PERFLAB_HOST" "cd /home/devworkspace-operator-load-tests && ./scripts/run_all_backup_loadtests.sh test-plans/backup-restore-openshift-internal-test-plan.json"
```

### 7. Monitor Test Execution

The test will run in the SSH session. Inform the user:
- Tests are running on the remote cluster
- Output will be streamed to the console
- Test results will be saved in the `outputs/` directory on the remote cluster
- They can interrupt with Ctrl+C if needed

### 8. Post-Test Actions

After test completion:
1. Show the output directory location
2. Offer to download results:
   ```bash
   scp -r "$PERFLAB_USER@$PERFLAB_HOST:/home/devworkspace-operator-load-tests/outputs/run_<timestamp>" ./
   ```
3. Offer to parse results into CSV if applicable

## Error Handling

- If SSH connection fails, verify credentials and network connectivity
- If operator not installed, direct user to installation documentation
- If config is incorrect, offer to fix it
- If repo not cloned, offer to clone it
- If test script fails, show error output and suggest checking cluster state

## Notes

- Tests can take significant time (40-150 minutes depending on configuration)
- Ensure cluster has sufficient resources for the test scale
- Monitor cluster health during test execution
- Results are saved with timestamps for later analysis
