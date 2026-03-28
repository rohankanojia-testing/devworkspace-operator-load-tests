# Load Testing Script Improvements

## Summary of Changes

The `scripts/run_all_loadtests.sh` script has been significantly enhanced with the following improvements:

### Key Features Added

1. **Better Output Organization**
   - All outputs saved to timestamped directories: `outputs/run_YYYYMMDD_HHMMSS/`
   - Logs organized in subdirectories with extracted metrics
   - Automatic README generation in output directory

2. **Comprehensive Reporting**
   - **Text Summary**: Comprehensive summary for quick viewing
   - **Metrics Extraction**: Auto-extract key metrics from each test log
   - **Test Status Tracking**: Track PASSED/FAILED/TIMEOUT/CLEANUP_FAILED status

3. **Improved Cleanup**
   - Cleanup runs **both before AND after** each test
   - Better error handling and logging during cleanup
   - Configurable cleanup timeout via `CLEANUP_MAX_WAIT`
   - Option to skip cleanup for debugging: `SKIP_CLEANUP=true`

4. **Test Management**
   - **Test Plan Preview**: Shows all tests before execution with 10-second countdown
   - **Per-test Timeouts**: Tests automatically killed if they exceed `TEST_TIMEOUT`
   - **Continue on Failure**: Suite continues even if individual tests fail
   - **Duration Tracking**: Tracks and reports duration for each test

5. **Better Visibility**
   - Color-coded output (green=success, red=error, yellow=warning, blue=info)
   - Progress tracking with test counters
   - Real-time cleanup status updates
   - Interrupt handling (Ctrl+C generates partial report)

6. **Configuration Flexibility**
   - Environment variables for all timeouts and settings
   - Easy test configuration with `add_test` helper
   - Support for custom test configurations
   - Test names auto-generated from parameters

### New Files

1. **scripts/run_all_loadtests.sh** (enhanced)
   - Main test runner with all improvements

2. **scripts/generate_report.sh** (new)
   - Regenerate reports from existing logs
   - Useful for interrupted runs or re-analysis

3. **scripts/README.md** (updated)
   - Comprehensive documentation
   - Usage examples and troubleshooting

## Quick Start

### Run All Tests (Default Configuration)

```bash
./scripts/run_all_loadtests.sh
```

This will:
1. Show a test plan with all configured tests
2. Wait 10 seconds (time to cancel if needed)
3. Run each test sequentially
4. Clean up between tests
5. Generate HTML and text reports
6. Save everything to `outputs/run_TIMESTAMP/`

### Customize Configuration

Edit `scripts/run_all_loadtests.sh` and modify the test definitions:

```bash
# Simple format: add_test <max-dws> <single|separate> <duration-min>
add_test 1000 single 40
add_test 2000 separate 60

# With extra arguments
add_test 500 single 30 "--max-vus 500"

# Fully custom test
add_custom_test "special-test" "--mode binary --max-vus 100 --max-devworkspaces 500"
```

### Run in Background (Overnight)

```bash
# Start in tmux session
tmux new -s loadtest
./scripts/run_all_loadtests.sh
# Detach: Ctrl+B, D

# Next morning: check results
tmux attach -t loadtest
ls -lht outputs/
cat outputs/run_*/summary.txt
```

### Environment Variables

```bash
# Custom output location
OUTPUT_DIR=/mnt/storage/results ./scripts/run_all_loadtests.sh

# Extend timeouts
TEST_TIMEOUT=21600 CLEANUP_MAX_WAIT=10800 ./scripts/run_all_loadtests.sh

# Debug mode (skip cleanup)
SKIP_CLEANUP=true ./scripts/run_all_loadtests.sh
```

## Output Structure

```
outputs/
├── README.md                    # Documentation
└── run_20260130_120000/
    ├── summary.txt              # Text summary ⭐ Check this!
    ├── test_suite.log           # Overall suite log
    └── logs/
        ├── 1000_single_ns_40m.log          # Test output
        ├── 1000_single_ns_40m_metrics.txt  # Extracted metrics
        ├── 2000_separate_ns_90m.log
        └── ...
```

## Viewing Results

### Text Summary

```bash
cat outputs/run_20260130_120000/summary.txt
```

### Individual Test Logs

```bash
# Full test output
cat outputs/run_20260130_120000/logs/1000_single_ns_40m.log

# Extracted metrics
cat outputs/run_20260130_120000/logs/1000_single_ns_40m_metrics.txt
```

## Cleanup Behavior

The script ensures thorough cleanup between tests:

### Single Namespace Mode
- Deletes all DevWorkspaces in test namespace
- Deletes the `loadtest-devworkspaces` namespace
- Waits for deletion to complete

### Separate Namespace Mode
- Finds all DevWorkspaces across all namespaces
- Deletes all namespaces with label `load-test=test-type`
- Waits for deletion to complete

### Cleanup Verification
- Polls every 30 seconds to verify cleanup
- Shows progress with resource counts
- Times out after `CLEANUP_MAX_WAIT` seconds (default: 2 hours)

## Test Statuses

| Status | Meaning |
|--------|---------|
| **PASSED** | Test completed successfully |
| **FAILED** | Test failed with errors |
| **TIMEOUT** | Test exceeded `TEST_TIMEOUT` |
| **CLEANUP_FAILED** | Pre-test cleanup failed |

## Tips for Overnight Runs

1. **Use tmux**:
   ```bash
   tmux new -s loadtest ./scripts/run_all_loadtests.sh
   ```

2. **Test your config first** with short durations:
   ```bash
   add_test 10 single 1  # Just 10 DevWorkspaces for 1 minute
   ```

3. **Monitor progress remotely**:
   ```bash
   tail -f outputs/run_*/logs/*.log
   ```

4. **Check estimated time**:
   - Look at the test plan preview (shown before execution)
   - Sum up all test durations + cleanup time (~30-60 min per cleanup)

## Regenerating Reports

If the script is interrupted or you want to re-analyze old runs:

```bash
./scripts/generate_report.sh outputs/run_20260130_120000
```

This regenerates `summary.txt` from the log files.

## Troubleshooting

### Cleanup Takes Too Long

```bash
# Check for stuck resources
oc get dw --all-namespaces
oc get ns -l load-test=test-type

# Increase timeout
CLEANUP_MAX_WAIT=10800 ./scripts/run_all_loadtests.sh
```

### Tests Timeout

```bash
# Increase per-test timeout to 6 hours
TEST_TIMEOUT=21600 ./scripts/run_all_loadtests.sh
```

### Need to Debug

```bash
# Skip cleanup to inspect resources
SKIP_CLEANUP=true ./scripts/run_all_loadtests.sh
```

## Example Configuration

Here's a sample overnight test configuration:

```bash
# Fast tests (40 min each)
add_test 500 single 40
add_test 1000 single 40
add_test 1500 single 40

# Medium tests (60 min each)
add_test 2000 single 60
add_test 1000 separate 60

# Long tests (90 min each)
add_test 2500 single 90
add_test 2000 separate 90
add_test 2500 separate 90
```

**Estimated total time**: ~10-12 hours (including cleanup between tests)

---

## Migration Notes

If you were using the old script:

### Before
```bash
./scripts/run_all_loadtests.sh
# Logs scattered in: load_test_results_TIMESTAMP/*.log
# No automatic report generation
# Manual cleanup required
```

### After
```bash
./scripts/run_all_loadtests.sh
# Everything in: outputs/run_TIMESTAMP/
# Automatic text report with all results
# Automatic cleanup between tests
# Better error handling and status tracking
```

The old script's functionality is preserved - you can still edit the test configurations in the same way, but now you get much better reporting and automation!
