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

### 6. Check for Existing tmux Session

Check if a load test is already running in tmux:

```bash
ssh "$PERFLAB_USER@$PERFLAB_HOST" "tmux ls 2>/dev/null | grep -q 'loadtest' && echo 'EXISTS' || echo 'NONE'"
```

If a session exists, ask user if they want to:
- Attach to the existing session to monitor
- Kill it and start a new test
- Leave it running and exit

### 7. Start Test in tmux Session

Create a new tmux session named `loadtest` and run the appropriate script:

#### Controller Load Tests
```bash
ssh "$PERFLAB_USER@$PERFLAB_HOST" "tmux new-session -d -s loadtest 'cd /home/devworkspace-operator-load-tests && ./scripts/run_all_loadtests.sh test-plans/controller-test-plan.json; exec bash'"
```

#### Webhook Load Tests
```bash
ssh "$PERFLAB_USER@$PERFLAB_HOST" "tmux new-session -d -s loadtest 'cd /home/devworkspace-operator-load-tests && ./scripts/run_all_webhook_loadtests.sh test-plans/webhook-performancelabs-test-plan.json; exec bash'"
```

#### Backup Load Tests
```bash
ssh "$PERFLAB_USER@$PERFLAB_HOST" "tmux new-session -d -s loadtest 'cd /home/devworkspace-operator-load-tests && ./scripts/run_all_backup_loadtests.sh test-plans/backup-restore-openshift-internal-test-plan.json; exec bash'"
```

Note: The `; exec bash` at the end keeps the tmux session alive after the test completes, allowing you to review the final output.

### 8. Monitor Test Execution Automatically

Inform the user that monitoring will happen automatically every 10 minutes.

**Monitoring loop:**
```bash
while true; do
  # Check if test is still running
  STATUS=$(ssh "$PERFLAB_USER@$PERFLAB_HOST" "pgrep -f 'run_all.*loadtest' && echo 'RUNNING' || echo 'COMPLETED'")

  if [[ "$STATUS" == "COMPLETED" ]]; then
    echo "Test completed!"
    break
  fi

  # Show last 15 lines of test output
  echo "========================================"
  echo "Test Status: RUNNING ($(date))"
  echo "========================================"
  ssh "$PERFLAB_USER@$PERFLAB_HOST" "tmux capture-pane -t loadtest -p | tail -15"
  echo ""

  # Wait 10 minutes before checking again
  echo "Next update in 10 minutes..."
  sleep 600
done
```

This provides periodic updates every 10 minutes without requiring user interaction.

### 9. Parse Results and Display CSV Automatically

After test completes, automatically parse logs and display results:

**Determine test type and parse accordingly:**

```bash
# Check which test was run based on output directory
if ssh "$PERFLAB_USER@$PERFLAB_HOST" "ls -d /home/devworkspace-operator-load-tests/outputs/backup_run_* 2>/dev/null" | grep -q backup_run; then
  TEST_TYPE="backup"
  OUTPUT_DIR=$(ssh "$PERFLAB_USER@$PERFLAB_HOST" "ls -td /home/devworkspace-operator-load-tests/outputs/backup_run_* 2>/dev/null | head -1")
  CSV_FILE="backup_load_test_results.csv"
  PARSE_SCRIPT="./scripts/parse-backup-outputs.sh"
elif ssh "$PERFLAB_USER@$PERFLAB_HOST" "ls -d /home/devworkspace-operator-load-tests/outputs/webhook_run_* 2>/dev/null" | grep -q webhook_run; then
  TEST_TYPE="webhook"
  OUTPUT_DIR=$(ssh "$PERFLAB_USER@$PERFLAB_HOST" "ls -td /home/devworkspace-operator-load-tests/outputs/webhook_run_* 2>/dev/null | head -1")
  CSV_FILE="webhook_load_test_results.csv"
  PARSE_SCRIPT="./scripts/parse-webhook-outputs.sh"
else
  TEST_TYPE="controller"
  OUTPUT_DIR=$(ssh "$PERFLAB_USER@$PERFLAB_HOST" "ls -td /home/devworkspace-operator-load-tests/outputs/run_* 2>/dev/null | head -1")
  CSV_FILE="controller_load_test_results.csv"
  PARSE_SCRIPT="./scripts/parse-controller-outputs.sh"
fi

echo "Test type detected: $TEST_TYPE"
echo "Output directory: $OUTPUT_DIR"
echo ""
echo "Parsing test results..."

# Parse logs into CSV
ssh "$PERFLAB_USER@$PERFLAB_HOST" "cd /home/devworkspace-operator-load-tests && $PARSE_SCRIPT $OUTPUT_DIR"

# Display CSV results
echo ""
echo "=========================================="
echo "CSV RESULTS"
echo "=========================================="
ssh "$PERFLAB_USER@$PERFLAB_HOST" "cat /home/devworkspace-operator-load-tests/$CSV_FILE"
echo ""
echo "=========================================="
```

**Instruct user to add to Google Sheets:**

Tell the user:
1. Copy the CSV output above
2. Open Google Sheets
3. Paste the CSV data into a cell
4. Select the pasted data
5. Go to **Data → Split text to columns**
6. Google Sheets will automatically detect comma delimiters and create columns

**Optional: Download detailed logs**
```bash
scp -r "$PERFLAB_USER@$PERFLAB_HOST:$OUTPUT_DIR" ./
```

**Clean up tmux session:**
```bash
ssh "$PERFLAB_USER@$PERFLAB_HOST" "tmux kill-session -t loadtest"
```

## Error Handling

- If SSH connection fails, verify credentials and network connectivity
- If operator not installed, direct user to installation documentation
- If config is incorrect, offer to fix it
- If repo not cloned, offer to clone it
- If test script fails, show error output and suggest checking cluster state
- If tmux session already exists, ask user how to proceed (attach/kill/exit)
- If tmux is not installed on remote host, suggest installing it or fall back to running in background with nohup

## tmux Benefits

Running tests in tmux provides:
- **Persistence**: Test continues running even if SSH connection drops
- **Detachability**: You can disconnect and reconnect without interrupting the test
- **Monitoring**: Check test progress periodically without staying connected
- **Session Recovery**: Reattach to view output at any time

## Manual tmux Commands (Optional)

While the skill automates monitoring, you can manually check the tmux session anytime:

- **List sessions**: `ssh "$PERFLAB_USER@$PERFLAB_HOST" "tmux ls"`
- **Attach to session** (watch in real-time): `ssh -t "$PERFLAB_USER@$PERFLAB_HOST" "tmux attach-session -t loadtest"`
- **Detach from session**: Press `Ctrl+b` then `d` (while attached)
- **View output without attaching**: `ssh "$PERFLAB_USER@$PERFLAB_HOST" "tmux capture-pane -t loadtest -p | tail -50"`
- **Kill session manually**: `ssh "$PERFLAB_USER@$PERFLAB_HOST" "tmux kill-session -t loadtest"`

## Notes

- Tests can take significant time (40-150 minutes depending on configuration)
- Ensure cluster has sufficient resources for the test scale
- **The skill automatically monitors test progress every 10 minutes** and displays updates
- **The skill automatically parses logs into CSV** after test completion
- **The skill displays the final CSV results** ready to copy into Google Sheets
- Test logs are saved in `outputs/` directory with timestamps on the remote host
- CSV output can be directly pasted into Google Sheets (Data → Split text to columns)
- The tmux session remains active after test completion for review
- The skill automatically cleans up tmux sessions after displaying results
- Keep CSV results in Google Sheets for easy tracking and comparison across test runs
