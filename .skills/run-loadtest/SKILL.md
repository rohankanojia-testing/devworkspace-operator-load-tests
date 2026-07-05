---
name: run-loadtest
description: >
  Run DevWorkspace Operator load tests in two separate modes: (1) CRC QE Amazon 32-node —
  log into cluster locally, run devspaces-prerelease-test-plan.json from your workstation;
  (2) Performance Labs — SSH into perf lab instance, run controller-test-plan.json remotely.
allowed-tools: Bash, AskUserQuestion, Read
---

Execute DevWorkspace Operator load tests in one of **two separate modes**. Test plan, `make test_load` args, DWO verify-only, and local execution apply **only** to CRC QE Amazon mode — Performance Labs uses SSH and different plans.

## Two Separate Modes

### Mode 1: CRC QE Amazon 32-node (`qe-aws`)

| Aspect | Detail |
|--------|--------|
| **Connect** | `oc login` **locally** on your workstation |
| **Run tests** | **Locally** — background script on your machine (`run-qe-aws-loadtest-background.sh`), no tmux |
| **DWO** | Pre-installed — verify version only |
| **Controller plan** | `test-plans/devspaces-prerelease-test-plan.json` |

```bash
./scripts/run_all_loadtests.sh test-plans/devspaces-prerelease-test-plan.json
```

### Mode 2: Performance Labs (`perflab`)

| Aspect | Detail |
|--------|--------|
| **Connect** | **SSH** into perf lab instance: `ssh ${PERFLAB_USER}@${PERFLAB_HOST}` |
| **Run tests** | **Remotely** — tmux on perf lab host via SSH |
| **DWO** | Install from testing catalog if needed |
| **Controller plan** | `test-plans/controller-test-plan.json` (not prerelease plan) |

```bash
ssh "${PERFLAB_USER}@${PERFLAB_HOST}" \
  "cd /home/devworkspace-operator-load-tests && ./scripts/run_all_loadtests.sh test-plans/controller-test-plan.json"
```

## Cluster Modes (summary)

| | **CRC QE AWS** (`qe-aws`) | **Performance Labs** (`perflab`) |
|---|---|---|
| **Cluster** | CRC QE Amazon 32-node OpenShift (cluster bot) | Bare-metal OCP |
| **Connect** | Local `oc login` | SSH to perf lab instance |
| **Execution** | Local background script (no tmux) | Remote perf lab host (tmux) |
| **Repo** | Local `REPO_DIR` | `REMOTE_REPO` (default: `/home/devworkspace-operator-load-tests`) — user-specified in Step 3 |
| **DWO** | Verify only — do not install | Install via testing catalog if needed |
| **Controller plan** | `devspaces-prerelease-test-plan.json` | `controller-test-plan.json` |

## Workflow Overview

**Hard rule:** Ask **cluster mode** (Step 0b) and **test type** (Step 0c) before any `oc`/`kubectl`/SSH commands. Do not auto-detect clusters or start tests without user selection.

1. **Verify repo** — must be in this load-testing git repo (hard gate, both modes)
2. **Select cluster mode** — CRC QE AWS (local) or Performance Labs (SSH) — **AskUserQuestion first**
3. **Select test type** — controller / webhook / backup — **AskUserQuestion before cluster access**
4. **Verify cluster access** — local `oc login` (qe-aws) or SSH to perf lab instance (perflab)
5. **Check and log cluster capacity** — per-node CPU/memory (saved for final report)
6. **Verify mode-specific prerequisites** — local tooling: kubectl, k6, jq (qe-aws) or **remote tooling: k6, kubectl on SSH host** + ask for remote repo path (perflab)
7. **Check DWO version** — confirm only (qe-aws) or install if needed (perflab)
8. **Patch DevWorkspaceOperatorConfig** — `imagePullPolicy`, `progressTimeout`
9. **Check for existing test run** — background process (qe-aws) or tmux session (perflab)
10. **Start test** — user runs background script from **their terminal** (qe-aws) or remote tmux (perflab)
11. **Monitor** — agent reads saved log files + optional `track-dw-status`; user may say "status"
12. **Generate report files** — CSV + markdown; merge multi-run logs if needed
13. **Copy results locally** — **mandatory for perflab** (scp from remote), optional for qe-aws (already local)
14. **Publish to Google** — Sheet + Doc (Step 12f)

---

## Step 0: Mandatory Gate — verify repo (both modes)

**Before any other step**, confirm you are in this load-testing git repo. If this fails, **stop**.

### 0a. Verify load-testing repository

Confirm the current working directory is a checkout of this load-testing repo (`dwo-k6-load-testing` / `devworkspace-operator-load-tests`):

```bash
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_DIR=""

if [[ -z "${REPO_DIR}" ]] \
   || [[ ! -f "${REPO_DIR}/scripts/run_all_loadtests.sh" ]] \
   || [[ ! -d "${REPO_DIR}/test-plans" ]] \
   || [[ ! -f "${REPO_DIR}/.skills/run-loadtest/SKILL.md" ]]; then
  echo "❌ Not in the load-testing repository"
  exit 1
fi

echo "✅ Load-testing repo: ${REPO_DIR}"
pwd
git remote -v
```

**If this fails**, tell the user:

```
❌ You are not in the DevWorkspace load-testing repository.

Navigate to your checkout:
  cd /path/to/dwo-k6-load-testing

Or clone it:
  git clone git@github.com:devfile/devworkspace-operator-load-tests.git
  cd devworkspace-operator-load-tests
```

**Do not continue** until `REPO_DIR` is set and all marker files exist.

### 0b. Select cluster mode (before cluster access check)

Use `AskUserQuestion` if not already specified:

**Options:**
1. **CRC QE Amazon 32-node (`qe-aws`)** — log into cluster locally, run tests on your machine
2. **Performance Labs (`perflab`)** — SSH into perf lab instance, run tests remotely

Store `CLUSTER_MODE` as `qe-aws` or `perflab`.

### 0c. Select test type (before cluster access check)

Use `AskUserQuestion` if not already specified — **do this in the same turn as Step 0b, before Step 1**:

**Options:**
1. **Controller Load Tests** — DevWorkspace controller at scale (**default for QE AWS pre-release**)
2. **Webhook Load Tests** — admission control and validation
3. **Backup Load Tests** — backup and restore under load (**OpenShift Internal registry only**)

Store `TEST_TYPE` as `controller`, `webhook`, or `backup`. Set `TEST_PLAN` from Step 7 tables based on `CLUSTER_MODE` + `TEST_TYPE`.

**Note:** Backup tests require OpenShift cluster with internal image registry enabled. They test PV backup/restore workflows by creating DevWorkspaces, backing up PVs to the internal registry, deleting workspaces, and restoring from backups.

---

## Step 1: Verify Cluster Access (mode-specific)

Cluster access differs by mode. **Do not** use local `oc login` workflow for Performance Labs — use SSH.

### CRC QE AWS (`qe-aws`) — local `oc login`

You work from your workstation with a local kubeconfig pointing at the QE cluster:

```bash
if ! command -v oc >/dev/null 2>&1; then
  echo "❌ oc CLI not found in PATH"
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "❌ Not logged into the CRC QE AWS cluster"
  exit 1
fi

echo "✅ Logged in locally as: $(oc whoami)"
oc cluster-info
```

If not logged in:

```
❌ Log into the CRC QE Amazon cluster locally:
  oc login <api-url> -u kubeadmin -p <password>

Request cluster from Slack cluster bot:
  launch 4.20 aws,no-spot
```

All subsequent `kubectl`/`oc` commands for qe-aws run **locally** (no SSH).

### Performance Labs (`perflab`) — SSH into perf lab instance

You do **not** run load tests from your laptop's kubeconfig. SSH into the Performance Labs host:

```bash
if [[ -z "$PERFLAB_USER" || -z "$PERFLAB_HOST" ]]; then
  echo "❌ PERFLAB_USER and PERFLAB_HOST must be set"
  exit 1
fi

ssh "${PERFLAB_USER}@${PERFLAB_HOST}" "echo '✅ SSH OK' && oc whoami && kubectl cluster-info"
```

If SSH fails, check VPN/network and credentials.

All subsequent cluster commands use `run_remote` (SSH). Tests run in tmux **on the perf lab instance**.

**Set `run_remote` helper and mode variables:**

```bash
run_remote() {
  if [[ "${CLUSTER_MODE}" == "perflab" ]]; then
    ssh "${PERFLAB_USER}@${PERFLAB_HOST}" "$@"
  else
    eval "$@"
  fi
}
```

| Variable | CRC QE AWS | Performance Labs |
|----------|------------|------------------|
| `REPO_DIR` | Local repo (Step 0a) | Local repo (Step 0a) — for skill orchestration/logs only |
| `REMOTE_REPO` | N/A | User-specified remote path (Step 3, default: `/home/devworkspace-operator-load-tests`) |
| `EXEC_REPO` | Same as `REPO_DIR` | Same as `REMOTE_REPO` (where tests execute) |

---

## Step 2: Check and Log Cluster Capacity

After mode selection, capture per-node allocatable CPU and memory from the **target cluster**:
- **CRC QE AWS:** local `kubectl` (your workstation kubeconfig)
- **Performance Labs:** `run_remote` via SSH to perf lab instance

**Run the capacity check:**

```bash
mkdir -p "${REPO_DIR}/outputs"

CAPACITY_LOG_FILE="${REPO_DIR}/outputs/cluster_capacity_$(date +%Y%m%d_%H%M%S).txt"

run_remote "kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory" \
  | tee "${CAPACITY_LOG_FILE}"

NODE_COUNT=$(run_remote "kubectl get nodes --no-headers | wc -l" | tr -d ' ')
```

**Show the user immediately** (confirm capacity before starting a long test):

```
==========================================
CLUSTER CAPACITY
==========================================
<output of kubectl get nodes ...>
------------------------------------------
Total nodes: ${NODE_COUNT}
Logged to: ${CAPACITY_LOG_FILE}
==========================================
```

Store `CAPACITY_LOG_FILE` and `NODE_COUNT` — **reprint this block in Step 12** as part of the final results summary.

If the command fails, stop and report the error (cluster API unreachable or insufficient RBAC).

---

## Step 3: Verify Mode-Specific Prerequisites

### CRC QE AWS (`qe-aws`)

**Verify local tooling** (tests run on your machine):

```bash
command -v kubectl && command -v k6 && command -v jq
```

**No tmux required** for CRC QE AWS — tests run via `./scripts/run-qe-aws-loadtest-background.sh` (nohup + PID file).

This is the **32-node AWS cluster** from cluster bot — not local CRC. Node count from Step 2 typically ~32 workers (+ masters).

### Performance Labs (`perflab`)

Already verified SSH in Step 1. Now verify **remote host prerequisites** and ask for remote repo path.

**Verify remote prerequisites** (k6, kubectl, jq on the remote host):

```bash
echo "Checking prerequisites on remote host..."

# Check k6
if ! run_remote "command -v k6 >/dev/null 2>&1"; then
  echo "❌ k6 not found on remote host ${PERFLAB_HOST}"
  echo ""
  echo "Install k6 on the remote host:"
  echo "  ssh ${PERFLAB_USER}@${PERFLAB_HOST}"
  echo "  # Download and install k6:"
  echo "  curl -L https://github.com/grafana/k6/releases/download/v0.47.0/k6-v0.47.0-linux-amd64.tar.gz | tar xz"
  echo "  sudo mv k6-v0.47.0-linux-amd64/k6 /usr/local/bin/"
  echo "  # Or install to user bin without sudo:"
  echo "  mkdir -p ~/.local/bin && mv k6-v0.47.0-linux-amd64/k6 ~/.local/bin/"
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\"  # add to ~/.bashrc"
  exit 1
fi

# Check kubectl
if ! run_remote "command -v kubectl >/dev/null 2>&1"; then
  echo "❌ kubectl not found on remote host ${PERFLAB_HOST}"
  exit 1
fi

# Check jq (optional but recommended)
if ! run_remote "command -v jq >/dev/null 2>&1"; then
  echo "⚠️  jq not found on remote host (optional, for JSON test plans)"
fi

echo "✅ Remote prerequisites verified:"
run_remote "k6 version | head -1"
run_remote "kubectl version --client=true --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1"
```

If prerequisites are missing, **stop** and show install instructions. Do not proceed without k6 and kubectl on the remote host.

**Ask for remote repo path:**

Use `AskUserQuestion` if not already specified:

**Question:** "What is the path to the load testing repository on the remote PerformanceLabs host?"

**Default:** `/home/devworkspace-operator-load-tests`

Store the answer in `REMOTE_REPO` (or use default if user accepts it).

Then confirm the repo exists on the remote host:

```bash
REMOTE_REPO="${REMOTE_REPO:-/home/devworkspace-operator-load-tests}"
run_remote "test -f ${REMOTE_REPO}/scripts/run_all_loadtests.sh && echo EXISTS || echo MISSING"
```

If the repo exists:
```
✅ Remote repository found at: ${REMOTE_REPO}
```

If missing, offer to clone:

```
❌ Repository not found at: ${REMOTE_REPO}

Clone it on the remote host?
```

**Options:** Yes, clone now / No, I'll set it up manually

If user chooses to clone:

```bash
ssh "${PERFLAB_USER}@${PERFLAB_HOST}" \
  "mkdir -p $(dirname ${REMOTE_REPO}) && cd $(dirname ${REMOTE_REPO}) && \
   git clone https://github.com/devfile/devworkspace-operator-load-tests.git $(basename ${REMOTE_REPO})"
```

Then verify again:

```bash
run_remote "test -f ${REMOTE_REPO}/scripts/run_all_loadtests.sh && echo EXISTS || echo MISSING"
```

Local `REPO_DIR` (Step 0a) is only for skill orchestration/logs; **tests execute on the SSH host at `${REMOTE_REPO}`**.

---

## Step 4: Check DevWorkspace Operator Version

Detect which DevWorkspace Operator (DWO) version is installed on the **target cluster**, then handle it differently per mode.

### 4a. Detect installed DWO version

```bash
DWO_VERSION_LOG_FILE="${REPO_DIR}/outputs/dwo_version_$(date +%Y%m%d_%H%M%S).txt"

{
  echo "=== DevWorkspace Operator CSV ==="
  run_remote "kubectl get csv -n openshift-operators -o custom-columns=NAME:.metadata.name,VERSION:.spec.version,PHASE:.status.phase 2>/dev/null | grep -E 'NAME|devworkspace-operator' || echo 'No DWO CSV found'"
  echo ""
  echo "=== DWO Deployments ==="
  run_remote "kubectl get deployment -n openshift-operators devworkspace-controller-manager devworkspace-webhook-server -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas/.spec.replicas,AVAILABLE:.status.availableReplicas 2>/dev/null || echo 'DWO deployments not found'"
  echo ""
  echo "=== DWO Subscription ==="
  run_remote "kubectl get subscription devworkspace-operator -n openshift-operators -o custom-columns=NAME:.metadata.name,CHANNEL:.spec.channel,CATALOG:.spec.source,CSV:.status.currentCSV 2>/dev/null || echo 'No DWO subscription found'"
} | tee "${DWO_VERSION_LOG_FILE}"

DWO_VERSION=$(run_remote "kubectl get csv -n openshift-operators -o jsonpath='{.items[?(@.spec.displayName==\"DevWorkspace Operator\")].spec.version}' 2>/dev/null" \
  | tr -d '[:space:]')
# Fallback if jsonpath returns empty:
if [[ -z "${DWO_VERSION}" ]]; then
  DWO_VERSION=$(run_remote "kubectl get csv -n openshift-operators --no-headers 2>/dev/null | grep devworkspace-operator | awk '{print \$NF}' | head -1" || true)
fi

DWO_CSV_PHASE=$(run_remote "kubectl get csv -n openshift-operators -o jsonpath='{.items[?(@.spec.displayName==\"DevWorkspace Operator\")].status.phase}' 2>/dev/null" \
  | tr -d '[:space:]')
```

Show the user:

```
==========================================
DEVWORKSPACE OPERATOR
==========================================
Installed version: ${DWO_VERSION:-NOT FOUND}
CSV phase:         ${DWO_CSV_PHASE:-N/A}
Cluster mode:      ${CLUSTER_MODE}
Logged to:         ${DWO_VERSION_LOG_FILE}
==========================================
```

Store `DWO_VERSION`, `DWO_CSV_PHASE`, and `DWO_VERSION_LOG_FILE` — **reprint in Step 12** final report.

---

### 4b. CRC QE AWS (`qe-aws`) — verify only, do not install

**CRC QE AWS only.** DWO is pre-installed on this cluster (upgraded from IIB during pre-release testing). **Do not run install/reinstall scripts.**

1. If `DWO_VERSION` is empty or deployments are missing → **stop** and tell the user:
   ```
   ❌ DevWorkspace Operator not found on QE cluster.
   Install/upgrade DWO from IIB first using the dwo-pre-release-testing skill, then return to load testing.
   ```

2. If DWO is installed, use `AskUserQuestion`:
   ```
   Detected DevWorkspace Operator version: ${DWO_VERSION} (${DWO_CSV_PHASE})

   Is this the correct version for your pre-release load test?
   ```
   **Options:** Yes, proceed / No, wrong version

3. **If Yes** → continue to Step 5.

4. **If No** → **stop** and guide the user:
   ```
   Upgrade DWO on the QE cluster to the target RC version before load testing.
   Use the dwo-pre-release-testing skill with the correct IIB URL, then re-run /run-loadtest.
   ```

---

### 4c. Performance Labs (`perflab`) — verify and install if needed

**Performance Labs only** (via SSH). Install DWO from testing catalog on the remote cluster when missing or wrong.

1. Ask the user for the **expected DWO version** (e.g. `0.41.0` RC build):
   ```
   What DevWorkspace Operator version should be installed for this load test?
   ```

2. Compare detected version to expected:

   **If version matches and CSV phase is `Succeeded`** → confirm with user and continue:
   ```
   ✅ DWO ${DWO_VERSION} is installed and Succeeded. Proceed with load tests?
   ```

   **If DWO is missing, wrong version, or CSV not Succeeded** → inform user and offer install:
   ```
   Current:  ${DWO_VERSION:-NOT INSTALLED} (${DWO_CSV_PHASE:-N/A})
   Expected: ${EXPECTED_DWO_VERSION}

   Install/reinstall DWO from the testing catalog on Performance Labs?
   ```
   **Options:** Yes, install now / No, stop

3. **If user chooses install**, run on the remote host via `run_remote`:

   ```bash
   run_remote "cd /home/devworkspace-operator-load-tests && ./scripts/reinstall_dwo_operator.sh"
   ```

   Prerequisites on the perf lab cluster:
   - `devworkspace-operator-testing-catalog` CatalogSource exists in `openshift-marketplace`
   - Remote host has `oc` access to the cluster

   After install completes, **re-detect version** (repeat 4a) and confirm `DWO_CSV_PHASE=Succeeded` before continuing.

4. **If user declines install** → **stop** (do not run load tests against wrong/missing operator).

---

## Step 5: Patch DevWorkspaceOperatorConfig

After DWO version is confirmed (Step 4), **patch** `DevWorkspaceOperatorConfig` with load-test settings to avoid flakes. This runs automatically on both cluster modes — do not skip.

### Required configuration

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

### 5a. Capture current config (before patch)

```bash
DWOC_LOG_FILE="${REPO_DIR}/outputs/dwoc_config_$(date +%Y%m%d_%H%M%S).txt"

{
  echo "=== BEFORE PATCH ==="
  run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators -o yaml 2>/dev/null || echo 'DevWorkspaceOperatorConfig not found'"
} | tee "${DWOC_LOG_FILE}"
```

### 5b. Patch or create

**If the config exists** — merge-patch workspace settings (preserves other fields such as backup config):

```bash
run_remote "kubectl patch devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators --type merge --patch '{\"config\":{\"workspace\":{\"imagePullPolicy\":\"IfNotPresent\",\"progressTimeout\":\"3600s\"}}}'"
```

**If the config does not exist** — create it:

```bash
run_remote "kubectl apply -f - <<'EOF'
apiVersion: controller.devfile.io/v1alpha1
kind: DevWorkspaceOperatorConfig
metadata:
  name: devworkspace-operator-config
  namespace: openshift-operators
config:
  workspace:
    imagePullPolicy: IfNotPresent
    progressTimeout: 3600s
EOF"
```

Use a single conditional:

```bash
if run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators" >/dev/null 2>&1; then
  echo "Patching existing DevWorkspaceOperatorConfig..."
  run_remote "kubectl patch devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators --type merge --patch '{\"config\":{\"workspace\":{\"imagePullPolicy\":\"IfNotPresent\",\"progressTimeout\":\"3600s\"}}}'"
else
  echo "Creating DevWorkspaceOperatorConfig..."
  run_remote "kubectl apply -f - <<'EOF'
apiVersion: controller.devfile.io/v1alpha1
kind: DevWorkspaceOperatorConfig
metadata:
  name: devworkspace-operator-config
  namespace: openshift-operators
config:
  workspace:
    imagePullPolicy: IfNotPresent
    progressTimeout: 3600s
EOF"
fi
```

### 5c. Verify patch succeeded

```bash
{
  echo ""
  echo "=== AFTER PATCH ==="
  run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators -o yaml"
  echo ""
  echo "=== VERIFICATION ==="
  run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators -o jsonpath='imagePullPolicy={.config.workspace.imagePullPolicy} progressTimeout={.config.workspace.progressTimeout}{\"\\n\"}'"
} | tee -a "${DWOC_LOG_FILE}"

DWOC_IMAGE_PULL_POLICY=$(run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators -o jsonpath='{.config.workspace.imagePullPolicy}'" | tr -d '[:space:]')
DWOC_PROGRESS_TIMEOUT=$(run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators -o jsonpath='{.config.workspace.progressTimeout}'" | tr -d '[:space:]')
```

**Confirm values match** — if not, **stop**:

```bash
if [[ "${DWOC_IMAGE_PULL_POLICY}" != "IfNotPresent" ]] || [[ "${DWOC_PROGRESS_TIMEOUT}" != "3600s" ]]; then
  echo "❌ DevWorkspaceOperatorConfig patch failed or values incorrect"
  echo "   Expected: imagePullPolicy=IfNotPresent, progressTimeout=3600s"
  echo "   Got:      imagePullPolicy=${DWOC_IMAGE_PULL_POLICY}, progressTimeout=${DWOC_PROGRESS_TIMEOUT}"
  exit 1
fi
```

Show the user:

```
✅ DevWorkspaceOperatorConfig patched
   imagePullPolicy:  IfNotPresent
   progressTimeout:  3600s
   Log: ${DWOC_LOG_FILE}
```

Store `DWOC_LOG_FILE`, `DWOC_IMAGE_PULL_POLICY`, and `DWOC_PROGRESS_TIMEOUT` — reprint in Step 12 final report.

---

## Step 6: Verify Remote Repository (Performance Labs only)

For **QE AWS**, Step 0a already confirmed the local repo — skip this step.

For **Performance Labs**, `REMOTE_REPO` was already confirmed in Step 3. This step is now part of Step 3 — skip to Step 7.

---

## Step 7: Select Test Type

**If not already chosen in Step 0c**, use `AskUserQuestion` now. Otherwise use the stored `TEST_TYPE` and set `TEST_PLAN` below.

### CRC QE AWS controller test plan (`qe-aws` only)

**This entire section applies only to CRC QE Amazon 32-node mode.** Performance Labs uses a different plan (see below).

`test-plans/devspaces-prerelease-test-plan.json` — run **locally**:

```bash
cd ${REPO_DIR}
./scripts/run_all_loadtests.sh test-plans/devspaces-prerelease-test-plan.json
```

Custom `make test_load` args baked into the plan:

| # | Test name (log prefix) | Key args |
|---|------------------------|----------|
| 1 | `1500_single_ns_40m` | `--separate-namespaces false --test-duration-minutes 40` |
| 2 | `1500_separate_ns_40m` | `--separate-namespaces true --test-duration-minutes 40` |

Both use: `--mode binary --create-automount-resources true --max-devworkspaces 1500 --delete-devworkspace-after-ready false`

When `CLUSTER_MODE=qe-aws` and the user selects controller tests, set:

```bash
TEST_RUNNER="./scripts/run_all_loadtests.sh"
TEST_PLAN="test-plans/devspaces-prerelease-test-plan.json"
```

Do **not** use this plan on Performance Labs. Do **not** offer alternative plans for QE AWS unless the user explicitly requests a smoke test (`minimal-test-plan.json`).

**Retry single namespace only** (if separate-ns passed but single-ns failed on pre-test cleanup):

Disable the separate-ns test in `devspaces-prerelease-test-plan.json` (`"enabled": false` on `1500_separate_ns_40m`), then:

```bash
# User's terminal — skip operator restart to avoid webhook pod timeout flake
RUN_ENV="RESTART_OPERATOR=false" \
  ./scripts/run-qe-aws-loadtest-background.sh \
  test-plans/devspaces-prerelease-test-plan.json
```

Re-enable separate-ns in the plan after the retry. Merge single-ns logs into the main `run_*` dir before generating the combined report (Step 12e).

### Performance Labs controller test plan (`perflab` only)

**SSH into perf lab instance** — use `controller-test-plan.json`, **not** `devspaces-prerelease-test-plan.json`:

```bash
ssh "${PERFLAB_USER}@${PERFLAB_HOST}" \
  "cd /home/devworkspace-operator-load-tests && ./scripts/run_all_loadtests.sh test-plans/controller-test-plan.json"
```

### Test plans by mode

| Test Type | CRC QE AWS (`qe-aws`) | Performance Labs (`perflab`) |
|-----------|----------------------|------------------------------|
| Controller | `test-plans/devspaces-prerelease-test-plan.json` — 1500 single ns + 1500 separate ns | `test-plans/controller-test-plan.json` — configurable scale |
| Webhook | `test-plans/webhook-performancelabs-test-plan.json` | `test-plans/webhook-performancelabs-test-plan.json` |
| Backup | `test-plans/backup-restore-openshift-internal-test-plan.json` | `test-plans/backup-restore-openshift-internal-test-plan.json` |

---

## Step 8: Check for Existing Test Run

### CRC QE AWS (`qe-aws`) — background process

```bash
./scripts/run-qe-aws-loadtest-background.sh --status
# RUNNING or COMPLETED
```

Also check PID file:

```bash
cat outputs/loadtest.pid 2>/dev/null && kill -0 "$(cat outputs/loadtest.pid)" 2>/dev/null && echo EXISTS || echo NONE
```

If a background run exists, ask the user:
- **Monitor** — `tail -f outputs/loadtest_background_*.log`
- **Stop and restart** — kill PID, then start a new run
- **Leave** it running and exit

### Performance Labs (`perflab`) — tmux session

```bash
run_remote "tmux ls 2>/dev/null | grep -q 'loadtest' && echo EXISTS || echo NONE"
```

If a session exists, ask the user:
- **Attach** to monitor the running test
- **Kill** and start a new test
- **Leave** it running and exit

---

## Step 8a: Pre-flight Check for Backup Tests (backup mode only)

**ONLY for backup load tests** — skip this step for controller/webhook tests.

Before starting backup tests, verify the OpenShift internal image registry is properly configured and accessible. Backup tests REQUIRE the internal registry to be running.

### Check internal registry deployment

```bash
if [[ "$TEST_TYPE" == "backup" ]]; then
  echo "Verifying OpenShift internal image registry..."
  
  # Check if image-registry deployment exists and is ready
  REGISTRY_READY=$(run_remote "oc get deployment/image-registry -n openshift-image-registry -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo '0'")
  
  if [[ "$REGISTRY_READY" -eq 0 ]]; then
    echo "❌ ERROR: OpenShift internal image registry is not running"
    echo ""
    echo "The image-registry deployment must be available for backup tests."
    echo "Check registry status:"
    echo "  oc get deployment/image-registry -n openshift-image-registry"
    echo "  oc get clusteroperator/image-registry"
    echo ""
    echo "Common fixes:"
    echo "  - Enable registry: oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{\"spec\":{\"managementState\":\"Managed\"}}'"
    echo "  - Check storage: oc get config.imageregistry.operator.openshift.io/cluster -o yaml"
    exit 1
  fi
  
  # Check if default route exists (optional but recommended for external access)
  ROUTE_EXISTS=$(run_remote "oc get route/default-route -n openshift-image-registry --no-headers 2>/dev/null | wc -l || echo '0'")
  
  if [[ "$ROUTE_EXISTS" -eq 0 ]]; then
    echo "⚠️  WARNING: No external route found for image registry"
    echo "Internal service will be used: image-registry.openshift-image-registry.svc:5000"
    echo ""
    echo "To create external route (optional):"
    echo "  oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{\"spec\":{\"defaultRoute\":true}}'"
  else
    ROUTE_HOST=$(run_remote "oc get route/default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null")
    echo "✅ Internal registry route: $ROUTE_HOST"
  fi
  
  echo "✅ Internal image registry is ready"
  echo ""
fi
```

**For CRC clusters specifically**: The internal registry is usually pre-configured and running. If not, enable it:

```bash
# Enable registry management
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge \
  -p '{"spec":{"managementState":"Managed"}}'

# Set storage to emptyDir (for CRC/testing only - not for production)
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge \
  -p '{"spec":{"storage":{"emptyDir":{}}}}'

# Optionally create external route
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge \
  -p '{"spec":{"defaultRoute":true}}'

# Wait for registry to be ready
oc wait --for=condition=Available --timeout=300s \
  deployment/image-registry -n openshift-image-registry
```

**If registry check fails**, stop and instruct the user to fix the registry before proceeding with backup tests.

### Verify DWOC is not already configured with external registry

```bash
if [[ "$TEST_TYPE" == "backup" ]]; then
  # Check current DWOC backup registry configuration
  CURRENT_REGISTRY=$(run_remote "oc get devworkspaceoperatorconfig -n openshift-operators devworkspace-operator-config -o jsonpath='{.config.workspace.backupCronJob.registry.path}' 2>/dev/null || echo ''")
  
  if [[ -n "$CURRENT_REGISTRY" ]] && [[ "$CURRENT_REGISTRY" != *"image-registry.openshift-image-registry"* ]] && [[ "$CURRENT_REGISTRY" != *"openshift-image-registry.apps"* ]]; then
    echo "⚠️  WARNING: DWOC is configured with external registry: $CURRENT_REGISTRY"
    echo "Backup test will reconfigure to use OpenShift internal registry"
    echo "External registries (quay.io, Docker Hub, etc.) are NOT permitted for backup load testing"
    echo ""
  fi
fi
```

---

## Step 9: Start Test

Set `TEST_PLAN` and `TEST_RUNNER` from Step 7 based on `CLUSTER_MODE`:

```bash
# CRC QE AWS controller (default for qe-aws)
TEST_RUNNER="./scripts/run_all_loadtests.sh"
TEST_PLAN="test-plans/devspaces-prerelease-test-plan.json"

# Performance Labs controller
TEST_RUNNER="./scripts/run_all_loadtests.sh"
TEST_PLAN="test-plans/controller-test-plan.json"
```

### Controller load tests

**CRC QE AWS — background script (no tmux):**

```bash
# USER MUST run this from their own terminal — NOT the Cursor agent shell
cd ${REPO_DIR}
./scripts/run-qe-aws-loadtest-background.sh test-plans/devspaces-prerelease-test-plan.json
```

**Agent limitation:** Long-running tests started from the Cursor agent shell die within seconds. The agent **must not** start the test — instruct the user to run the command above, then monitor via saved log files.

**Skip operator restart** when retrying after webhook timeout flake (DWO already healthy):

```bash
RUN_ENV="RESTART_OPERATOR=false" \
  ./scripts/run-qe-aws-loadtest-background.sh test-plans/devspaces-prerelease-test-plan.json
```

Logs to `outputs/loadtest_background_<timestamp>.log`. PID in `outputs/loadtest.pid`.

**Agent/user monitoring files** (stable paths — read these to check progress without attaching to the process):

| File | Purpose |
|------|---------|
| `outputs/loadtest_current.log` | Symlink to the active background log |
| `outputs/loadtest.meta` | `LOG_FILE`, `PID`, `TEST_PLAN`, `STARTED_AT`, `STATUS` |
| `outputs/loadtest.pid` | Process ID of the background runner |
| `outputs/run_<timestamp>/logs/*.log` | Per-test logs once each test starts |

```bash
# Agent monitors by reading saved output (no tmux, no live attach required)
tail -30 outputs/loadtest_current.log
./scripts/run-qe-aws-loadtest-background.sh --status
cat outputs/loadtest.meta
```

**Important:** Start the background script from the **user's terminal** (not the Cursor agent shell) so the long-running process survives. The agent monitors afterward by reading `outputs/loadtest_current.log` and `outputs/loadtest.meta`.

**Performance Labs — remote tmux via SSH on perf lab instance:**

```bash
ssh "${PERFLAB_USER}@${PERFLAB_HOST}" \
  "tmux new-session -d -s loadtest 'cd /home/devworkspace-operator-load-tests && ./scripts/run_all_loadtests.sh test-plans/controller-test-plan.json; exec bash'"
```

### Webhook load tests

**CRC QE AWS (local background):**

```bash
cd ${REPO_DIR}
nohup ./scripts/run_all_webhook_loadtests.sh test-plans/webhook-performancelabs-test-plan.json \
  > outputs/loadtest_background_$(date +%Y%m%d_%H%M%S).log 2>&1 &
echo $! > outputs/loadtest.pid
```

**Performance Labs:**

```bash
ssh "${PERFLAB_USER}@${PERFLAB_HOST}" \
  "tmux new-session -d -s loadtest 'cd /home/devworkspace-operator-load-tests && ./scripts/run_all_webhook_loadtests.sh test-plans/webhook-performancelabs-test-plan.json; exec bash'"
```

### Backup Load Tests

**Prerequisites:** Backup tests require **OpenShift cluster with internal image registry enabled**. They test PV backup/restore by:
1. Creating DevWorkspaces with PVs
2. Backing up PVs to OpenShift internal registry (`image-registry.openshift-image-registry.svc:5000`)
3. Deleting DevWorkspaces
4. Restoring PVs from registry backups

**IMPORTANT:** Only use **OpenShift Internal registry** for backup load testing. **External registries (quay.io, Docker Hub, etc.) are NOT permitted** due to a past quay.io outage that affected production systems during load testing. Internal registry keeps all backup traffic within the cluster and prevents external service disruptions.

Verify internal registry is running:
```bash
oc get deployment/image-registry -n openshift-image-registry
oc get route/default-route -n openshift-image-registry
```

**QE AWS (local background):**

```bash
cd ${REPO_DIR}
nohup ./scripts/run_all_backup_loadtests.sh test-plans/backup-restore-openshift-internal-test-plan.json \
  > outputs/loadtest_background_$(date +%Y%m%d_%H%M%S).log 2>&1 &
echo $! > outputs/loadtest.pid
```

**Performance Labs:**

```bash
ssh "${PERFLAB_USER}@${PERFLAB_HOST}" \
  "tmux new-session -d -s loadtest 'cd /home/devworkspace-operator-load-tests && ./scripts/run_all_backup_loadtests.sh test-plans/backup-restore-openshift-internal-test-plan.json; exec bash'"
```

Replace the test plan path if the user chose a non-default plan in Step 7.

Set `EXEC_REPO` to the directory where tests actually run:
- **QE AWS:** `EXEC_REPO="${REPO_DIR}"` (local repo from Step 0a)
- **Performance Labs:** `EXEC_REPO="/home/devworkspace-operator-load-tests"` (remote host)

### Controller tests — start DevWorkspace phase tracker (qe-aws + perflab)

Alongside the load test, start **`track_dw.sh`** (or the repo copy) to poll workspace phases into CSV. The agent monitors this file for live workspace counts.

**CRC QE AWS — background tracker (recommended poll: 10s for long runs):**

```bash
# Detect latest run_* dir once the suite creates it, or set manually:
RUN_DIR=$(ls -td ${REPO_DIR}/outputs/run_* 2>/dev/null | head -1)

OUTPUT_FILE="${RUN_DIR}/dw_status.csv" \
  ./scripts/track-dw-status-background.sh 10
```

**Or use the user's script directly:**

```bash
export TRACK_DW_SCRIPT=/Users/rokumar/temp-scripts/track_dw.sh
OUTPUT_FILE="${RUN_DIR}/dw_status.csv" \
  ./scripts/track-dw-status-background.sh 10
```

**Performance Labs:**

```bash
run_remote "cd ${EXEC_REPO} && OUTPUT_FILE=outputs/run_<timestamp>/dw_status.csv ./scripts/track-dw-status-background.sh 10"
```

| Tracker file | Purpose |
|--------------|---------|
| `outputs/run_<timestamp>/dw_status.csv` | Timestamped phase counts (Starting, Running, Failed, …) |
| `outputs/track_dw.meta` | Tracker PID, CSV path, poll interval |
| `outputs/track_dw.pid` | Background tracker PID |

Example live output:

```
16:40:13 → 🟡 Starting:96  🟢 Running:100  ⏸️ Stopped:0  🟠 Failing:0  🔴 Failed:0  ⚫ Terminating:0
```

Stop tracker when the suite completes: `./scripts/track-dw-status-background.sh --stop`

---

## Step 10: Monitor Test Execution

**qe-aws:** Agent does **not** attach to the process. On user "status" or periodic check, read saved files:

```bash
./scripts/run-qe-aws-loadtest-background.sh --status
tail -30 outputs/loadtest_current.log
tail -5 outputs/run_*/logs/1500_single_ns_40m.log   # or separate_ns
tail -3 outputs/run_*/dw_status.csv 2>/dev/null      # if tracker running
oc get dw -n loadtest-devworkspaces --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c
```

**perflab:** Capture tmux pane or poll remote logs.

Optional automatic loop (every 10 minutes while user waits):

```bash
while true; do
  if [[ "${CLUSTER_MODE}" == "qe-aws" ]]; then
    STATUS=$(./scripts/run-qe-aws-loadtest-background.sh --status 2>/dev/null | head -1 || echo COMPLETED)
  else
    STATUS=$(run_remote "pgrep -f 'run_all.*loadtest' >/dev/null && echo RUNNING || echo COMPLETED")
    MONITOR_CMD="tmux capture-pane -t loadtest -p | tail -15"
  fi

  if [[ "$STATUS" == "COMPLETED" ]]; then
    echo "Test completed! Results are in ${EXEC_REPO}/outputs/ — see Step 11."
    rm -f "${REPO_DIR}/outputs/loadtest.pid" 2>/dev/null || true
    break
  fi

  echo "========================================"
  echo "Test Status: RUNNING ($(date)) — mode: ${CLUSTER_MODE}"
  echo "========================================"
  if [[ "${CLUSTER_MODE}" == "qe-aws" ]]; then
    ./scripts/run-qe-aws-loadtest-background.sh --status 2>/dev/null | tail -20
    echo ""
    echo "--- DevWorkspace phases (dw_status.csv) ---"
    DW_CSV=$(grep -E '^OUTPUT_FILE=' "${REPO_DIR}/outputs/track_dw.meta" 2>/dev/null | cut -d= -f2-)
    if [[ -z "${DW_CSV}" ]]; then
      DW_CSV=$(ls -t "${REPO_DIR}"/outputs/run_*/dw_status.csv 2>/dev/null | head -1 || echo "${REPO_DIR}/outputs/dw_status.csv")
    fi
    if [[ -f "${DW_CSV}" ]]; then
      echo "CSV: ${DW_CSV}"
      tail -3 "${DW_CSV}"
    else
      oc get dw --all-namespaces -o json 2>/dev/null | jq -r '
        ["Starting","Running","Stopped","Failing","Failed","Terminating"] as $p
        | $p | map(. + ":" + ([.items[]? | select(.status.phase == .)] | length | tostring)) | join("  ")
      ' 2>/dev/null || echo "(tracker not started — run track-dw-status-background.sh)"
    fi
  else
    run_remote "tmux capture-pane -t loadtest -p | tail -15"
  fi
  echo ""
  echo "Next update in 10 minutes..."
  sleep 600
done
```

---

## Step 11: Test Complete — Results in `outputs/`

When `run_all_loadtests.sh` (or webhook/backup suite runners) finishes, **all test results are written under the `outputs/` folder** in the repo where tests ran:

| Mode | Results location |
|------|------------------|
| **CRC QE AWS** | `${REPO_DIR}/outputs/` (local) |
| **Performance Labs** | `/home/devworkspace-operator-load-tests/outputs/` (on SSH host) |

### Output directory layout

Each suite run creates a **timestamped subdirectory** under `outputs/`:

| Test type | Run directory pattern | Key files |
|-----------|----------------------|-----------|
| Controller | `outputs/run_YYYYMMDD_HHMMSS/` | `summary.txt`, `logs/<test_name>.log`, `logs/<test_name>_metrics.txt` |
| Webhook | `outputs/webhook_run_YYYYMMDD_HHMMSS/` | `summary.txt`, `logs/*.log` |
| Backup | `outputs/backup_run_YYYYMMDD_HHMMSS/` | `summary.txt`, `logs/*.log` |

**Full test run logs** are under `logs/` inside the run directory:

```
outputs/run_20260520_031456/logs/1500_single_ns_40m.log
outputs/run_20260520_031456/logs/1500_separate_ns_40m.log
```

Each test also produces `<test_name>_metrics.txt` and optionally `<test_name>_failure_report.csv` in the same `logs/` folder.

Pre-test snapshots (capacity, DWO version, DWOC config) are also saved under `${REPO_DIR}/outputs/` locally.

### Locate the latest `run_*` directory

After the monitoring loop reports `COMPLETED`, find the newest timestamped output directory:

```bash
# Controller — latest run_* (most common for CRC QE AWS prerelease)
OUTPUT_DIR=$(run_remote "ls -td ${EXEC_REPO}/outputs/run_* 2>/dev/null | head -1")
echo "Latest run: ${OUTPUT_DIR}"

# Webhook — latest webhook_run_*
# OUTPUT_DIR=$(run_remote "ls -td ${EXEC_REPO}/outputs/webhook_run_* 2>/dev/null | head -1")

# Backup — latest backup_run_*
# OUTPUT_DIR=$(run_remote "ls -td ${EXEC_REPO}/outputs/backup_run_* 2>/dev/null | head -1")
```

Example: `outputs/run_20260520_031456/` is the latest `run_*` dir for that suite.

Show the user where results landed:

```bash
echo "=========================================="
echo "TEST RESULTS"
echo "=========================================="
echo "Results folder: ${OUTPUT_DIR}"
run_remote "ls -la ${OUTPUT_DIR}"
echo ""
echo "Summary:"
run_remote "cat ${OUTPUT_DIR}/summary.txt 2>/dev/null || echo 'summary.txt not found'"
echo "=========================================="
```

**CRC QE AWS example** (after `devspaces-prerelease-test-plan.json`):

```
outputs/run_20260520_031456/
├── summary.txt
└── logs/
    ├── 1500_single_ns_40m.log          # full test run log
    ├── 1500_single_ns_40m_metrics.txt
    ├── 1500_separate_ns_40m.log       # full test run log
    └── 1500_separate_ns_40m_metrics.txt
```

Inform the user they can inspect full logs directly:

```bash
# CRC QE AWS (local) — latest run_*
LATEST_RUN=$(ls -td outputs/run_* 2>/dev/null | head -1)
cat "${LATEST_RUN}/logs/1500_single_ns_40m.log"
cat "${LATEST_RUN}/logs/1500_separate_ns_40m.log"
ls "${LATEST_RUN}/logs/"

# Performance Labs (remote)
ssh "${PERFLAB_USER}@${PERFLAB_HOST}" "ls -la /home/devworkspace-operator-load-tests/outputs/run_*/logs/"
```

Store `OUTPUT_DIR` for Step 12 parsing.

### Parse controller results to CSV

Controller logs under `outputs/run_*` are parsed with:

```bash
# CRC QE AWS (local) — replace with latest run_* timestamp
./scripts/parse-controller-outputs.sh outputs/run_20260520_031456/

# Or using the detected latest directory
cd "${EXEC_REPO}"
./scripts/parse-controller-outputs.sh "${OUTPUT_DIR}"
```

**Performance Labs** (parse on remote host via SSH):

```bash
ssh "${PERFLAB_USER}@${PERFLAB_HOST}" \
  "cd /home/devworkspace-operator-load-tests && ./scripts/parse-controller-outputs.sh outputs/run_20260520_031456/"
```

This writes/appends to `controller_load_test_results.csv` in the repo root and prints the CSV to stdout.

For webhook or backup tests, use `./scripts/parse-webhook-outputs.sh` or `./scripts/parse-backup-outputs.sh` with the matching `webhook_run_*` or `backup_run_*` directory instead.

This writes/appends to `controller_load_test_results.csv` in the repo root during parsing. Step 12 copies the final CSV into the run directory.

---

## Step 12: Generate Report Files and Final Summary

After **both** controller tests finish (1500 single ns + 1500 separate ns), generate and share two files inside the latest `outputs/run_<timestamp>/` directory:

| File | Purpose |
|------|---------|
| `controller_load_test_results.csv` | Parsed metrics for both single and separate namespace runs |
| `loadtest_report.md` | Detailed markdown report (cluster info, DWOC config, test commands, failures) |

### 12e. Generate CSV + markdown report

**If both tests ran in one suite** — one `outputs/run_<timestamp>/` with both log files.

**If tests ran in separate runs** (e.g. single-ns retried later) — merge logs into one run dir before generating:

```bash
# Example: separate-ns in run_20260703_163649, single-ns in run_20260703_181525
REPORT_RUN_DIR="outputs/run_20260703_163649"
cp outputs/run_20260703_181525/logs/1500_single_ns_40m.log "${REPORT_RUN_DIR}/logs/"
cp outputs/run_20260703_181525/logs/1500_single_ns_40m_metrics.txt "${REPORT_RUN_DIR}/logs/"
# Remove stale/placeholder failure CSV if single-ns had 0 failures
rm -f "${REPORT_RUN_DIR}/logs/1500_single_ns_40m_failure_report.csv"

cd "${REPO_DIR}"
./scripts/generate-prerelease-loadtest-report.sh "${REPORT_RUN_DIR}" "${CAPACITY_LOG_FILE}"
```

**Report outputs must NOT contain raw k6 console text** (no `✓ DevWorkspace created`, `average_etcd_cpu`, `running (0h...)`, threshold messages). The generator only includes:
- Parsed numeric CSV rows (`controller_load_test_results.csv`)
- Cluster capacity table
- Failure **CSV rows** from `*_failure_report.csv` (real `load-test-ns-*` entries) or `None`

```bash
OUTPUT_DIR=$(run_remote "ls -td ${EXEC_REPO}/outputs/run_* 2>/dev/null | head -1")

# CRC QE AWS (local)
cd "${REPO_DIR}"
./scripts/generate-prerelease-loadtest-report.sh "${OUTPUT_DIR}" "${CAPACITY_LOG_FILE}"

# Performance Labs (remote via SSH)
ssh "${PERFLAB_USER}@${PERFLAB_HOST}" \
  "cd /home/devworkspace-operator-load-tests && ./scripts/generate-prerelease-loadtest-report.sh ${OUTPUT_DIR}"
```

**Or using `run_remote`:**

```bash
run_remote "cd ${EXEC_REPO} && ./scripts/generate-prerelease-loadtest-report.sh ${OUTPUT_DIR} ${CAPACITY_LOG_FILE}"
```

The script prints and **must share with the user**:

```
==========================================
REPORT FILES (share after both tests finish)
==========================================
CSV:      outputs/run_20260520_031456/controller_load_test_results.csv
Markdown: outputs/run_20260520_031456/loadtest_report.md
==========================================
```

### Markdown report format (`loadtest_report.md`)

```markdown
## Cluster Info
<kubectl get nodes -o custom-columns=NAME,CPU,MEMORY output>

Edit DevWorkspaceOperatorConfig in openshift-operators to increase progressTimeout to 3600s
progressTimeout: 3600s

Increase each node capacity from 250 to 500 pods

## Test Results

### Single Namespace
1500
make test_load ARGS=" --mode binary --create-automount-resources true --max-devworkspaces 1500 ..."
#### Failures
<failure report CSV or metrics summary, or "None">

### Separate Namespace
1500
make test_load ARGS=" --mode binary --create-automount-resources true --max-devworkspaces 1500 --separate-namespaces true ..."
#### Failures
<failure report CSV or metrics summary, or "None">

## CSV Results
<full controller_load_test_results.csv contents>
```

Failures are pulled from `logs/1500_single_ns_40m_failure_report.csv` and `logs/1500_separate_ns_40m_failure_report.csv` when present; otherwise `None`.

After generating, **tell the user both file paths** and display `cat` of the markdown report summary.

### 12f. Publish results to Google Sheet and Google Doc

After sharing report file paths (Step 12e), **instruct the user** to publish results to Google with these exact titles for the current pre-release cycle:

| Destination | Title |
|-------------|-------|
| **Google Sheet** | `DevSpaces 3.29.0-RC.02.07 Load Testing Results` |
| **Google Doc** | `DevSpaces 3.29.0-RC.02.07 Load Testing` |

Update the version in both titles when testing a different RC (e.g. replace `3.29.0-RC.02.07` with the target release).

**Google Sheet — import CSV:**

1. Open or create Google Sheet: **DevSpaces 3.29.0-RC.02.07 Load Testing Results**
2. Open the generated CSV locally:
   ```bash
   cat "${OUTPUT_DIR}/controller_load_test_results.csv"
   ```
3. **File → Import** (or copy all CSV contents and paste into cell A1)
4. Choose **Replace current sheet** or **Insert new sheet**
5. Separator: **Comma**
6. Confirm columns: DevWorkspaces Created, DevWorkspace Ready, Ready Failed (%), Average CPU, etc.

**Google Doc — paste markdown report:**

1. Open or create Google Doc: **DevSpaces 3.29.0-RC.02.07 Load Testing**
2. Open the markdown report locally:
   ```bash
   cat "${OUTPUT_DIR}/loadtest_report.md"
   ```
3. Copy the full contents of `loadtest_report.md`
4. Paste into the Google Doc (headings and code blocks will paste as plain text — format as needed)
5. Ensure **Cluster Info** (node CPU/memory table), **test commands**, **Failures**, and **CSV Results** sections are included

Tell the user both Google destinations by name so they can find the right Sheet and Doc in Drive.

---

## Step 12 (continued): Final Summary Sections

### 12a. Reprint cluster capacity (from Step 2)

Always include the capacity snapshot captured at test start:

```bash
echo ""
echo "=========================================="
echo "CLUSTER CAPACITY (captured at test start)"
echo "=========================================="
echo "Cluster mode: ${CLUSTER_MODE}"
echo "Total nodes: ${NODE_COUNT}"
echo "Log file: ${CAPACITY_LOG_FILE}"
echo "------------------------------------------"
cat "${CAPACITY_LOG_FILE}"
echo "=========================================="
```

### 12b. Reprint DWO version (from Step 4)

Always include the operator version snapshot captured before the test:

```bash
echo ""
echo "=========================================="
echo "DEVWORKSPACE OPERATOR (captured at test start)"
echo "=========================================="
echo "Version: ${DWO_VERSION:-NOT FOUND}"
echo "CSV phase: ${DWO_CSV_PHASE:-N/A}"
echo "Log file: ${DWO_VERSION_LOG_FILE}"
echo "------------------------------------------"
cat "${DWO_VERSION_LOG_FILE}"
echo "=========================================="
```

### 12c. Reprint DevWorkspaceOperatorConfig (from Step 5)

```bash
echo ""
echo "=========================================="
echo "DEVWORKSPACE OPERATOR CONFIG (patched at test start)"
echo "=========================================="
echo "imagePullPolicy:  ${DWOC_IMAGE_PULL_POLICY}"
echo "progressTimeout:  ${DWOC_PROGRESS_TIMEOUT}"
echo "Log file:         ${DWOC_LOG_FILE}"
echo "------------------------------------------"
cat "${DWOC_LOG_FILE}"
echo "=========================================="
```

### 12d. Parse `outputs/run_*` to CSV and display

Use the latest `run_*` directory from Step 11. For **controller** tests (CRC QE AWS prerelease):

```bash
# Detect latest run_* timestamp directory
OUTPUT_DIR=$(run_remote "ls -td ${EXEC_REPO}/outputs/run_* 2>/dev/null | head -1")

# Parse to CSV — e.g. ./scripts/parse-controller-outputs.sh outputs/run_20260520_031456/
run_remote "cd ${EXEC_REPO} && ./scripts/parse-controller-outputs.sh ${OUTPUT_DIR}"

echo ""
echo "=========================================="
echo "CSV RESULTS (controller_load_test_results.csv)"
echo "=========================================="
run_remote "cat ${EXEC_REPO}/controller_load_test_results.csv"
echo "=========================================="
```

**Webhook / backup** — auto-detect and use the matching parser:

```bash
if run_remote "ls -d ${EXEC_REPO}/outputs/backup_run_* 2>/dev/null" | grep -q backup_run; then
  OUTPUT_DIR=$(run_remote "ls -td ${EXEC_REPO}/outputs/backup_run_* 2>/dev/null | head -1")
  run_remote "cd ${EXEC_REPO} && ./scripts/parse-backup-outputs.sh ${OUTPUT_DIR}"
  CSV_FILE="backup_load_test_results.csv"
elif run_remote "ls -d ${EXEC_REPO}/outputs/webhook_run_* 2>/dev/null" | grep -q webhook_run; then
  OUTPUT_DIR=$(run_remote "ls -td ${EXEC_REPO}/outputs/webhook_run_* 2>/dev/null | head -1")
  run_remote "cd ${EXEC_REPO} && ./scripts/parse-webhook-outputs.sh ${OUTPUT_DIR}"
  CSV_FILE="webhook_load_test_results.csv"
else
  OUTPUT_DIR=$(run_remote "ls -td ${EXEC_REPO}/outputs/run_* 2>/dev/null | head -1")
  run_remote "cd ${EXEC_REPO} && ./scripts/parse-controller-outputs.sh ${OUTPUT_DIR}"
  CSV_FILE="controller_load_test_results.csv"
fi

run_remote "cat ${EXEC_REPO}/${CSV_FILE}"
```

The **final report order** shown to the user:
1. **Report file locations** — `controller_load_test_results.csv` and `loadtest_report.md` in `outputs/run_<timestamp>/` (Step 12e)
2. Test results location + `summary.txt` from `outputs/` (Step 11)
3. **Copy results locally** — **Performance Labs only**: download run directory + snapshots to local `${PWD}/outputs/` (Step 12g)
4. Cluster capacity (Step 12a)
5. DWO version (Step 12b)
6. DevWorkspaceOperatorConfig (Step 12c)
7. Parsed CSV display (Step 12d)
8. **Publish to Google** — Sheet + Doc titles and import/paste steps (Step 12f)

**For Performance Labs**, after Step 12g completes, **all file paths shown to the user must reference the LOCAL copies** in `${PWD}/outputs/`, not the remote paths.

### 12g. Copy results to local directory (Performance Labs mandatory, QE AWS optional)

**Performance Labs — MANDATORY: Download results from remote host**

After parsing completes, copy the **entire run directory** from the remote host to your local working directory (where Claude/Cursor was launched):

```bash
# Determine local destination — current working directory where agent launched
LOCAL_DEST_DIR="${PWD}/outputs"
mkdir -p "${LOCAL_DEST_DIR}"

# Download the latest run directory from remote
REMOTE_RUN_DIR="${OUTPUT_DIR}"  # e.g., /home/devworkspace-operator-load-tests/outputs/run_20260520_031456
LOCAL_RUN_NAME="$(basename ${REMOTE_RUN_DIR})"

echo "=========================================="
echo "COPYING RESULTS FROM REMOTE HOST"
echo "=========================================="
echo "Remote dir: ${PERFLAB_USER}@${PERFLAB_HOST}:${REMOTE_RUN_DIR}"
echo "Local dest: ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}"
echo "=========================================="

scp -r "${PERFLAB_USER}@${PERFLAB_HOST}:${REMOTE_RUN_DIR}" "${LOCAL_DEST_DIR}/"

# Verify copy succeeded
if [[ -d "${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}" ]]; then
  echo "✅ Results copied successfully to: ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}"
  echo ""
  echo "Local files:"
  ls -lh "${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}"
  echo ""
  echo "CSV: ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/controller_load_test_results.csv"
  echo "Report: ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/loadtest_report.md"
else
  echo "❌ Failed to copy results locally"
  exit 1
fi
```

**Also copy pre-test snapshots** (capacity, DWO version, DWOC config) from remote `outputs/`:

```bash
echo "Copying pre-test snapshots..."
scp "${PERFLAB_USER}@${PERFLAB_HOST}:${EXEC_REPO}/outputs/cluster_capacity_*.txt" "${LOCAL_DEST_DIR}/" 2>/dev/null || true
scp "${PERFLAB_USER}@${PERFLAB_HOST}:${EXEC_REPO}/outputs/dwo_version_*.txt" "${LOCAL_DEST_DIR}/" 2>/dev/null || true
scp "${PERFLAB_USER}@${PERFLAB_HOST}:${EXEC_REPO}/outputs/dwoc_config_*.txt" "${LOCAL_DEST_DIR}/" 2>/dev/null || true

echo "✅ All results copied to local: ${LOCAL_DEST_DIR}"
```

**After copying**, update all file paths shown to user to reference **local paths**:

```
==========================================
FINAL RESULTS (LOCAL COPIES)
==========================================
Run directory: ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}
CSV:           ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/controller_load_test_results.csv
Report:        ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/loadtest_report.md

Pre-test snapshots:
  Cluster capacity: ${LOCAL_DEST_DIR}/cluster_capacity_*.txt
  DWO version:      ${LOCAL_DEST_DIR}/dwo_version_*.txt
  DWOC config:      ${LOCAL_DEST_DIR}/dwoc_config_*.txt
==========================================
```

**CRC QE AWS — optional backup copy**

Results are already local in `${REPO_DIR}/outputs/`. Optionally make a timestamped backup:

```bash
# Optional — create timestamped backup
cp -r "${OUTPUT_DIR}" "${REPO_DIR}/outputs/loadtest-results-$(date +%Y%m%d_%H%M%S)/"
```

**Clean up after completion:**

```bash
# CRC QE AWS — remove stale PID file
rm -f "${REPO_DIR}/outputs/loadtest.pid"

# Performance Labs — kill tmux session
run_remote "tmux kill-session -t loadtest 2>/dev/null || true"
```

---

## Error Handling

| Issue | CRC QE AWS | Performance Labs |
|-------|--------------|------------------|
| Not logged in | **Stop** — local `oc login` (Step 1) | N/A — use SSH, not local `oc` |
| SSH failure | N/A | **Stop** — `ssh ${PERFLAB_USER}@${PERFLAB_HOST}` must work (Step 1) |
| Not in repo (Step 0a) | **Stop** — `cd` to repo or clone | Same — local repo for orchestration/logs |
| DWO not installed | **Stop** — install via `dwo-pre-release-testing` / IIB first | Offer `./scripts/reinstall_dwo_operator.sh` via SSH |
| DWO wrong version | **Stop** — user confirms version in Step 4b | Reinstall from testing catalog in Step 4c |
| DWOC patch failed | **Stop** — verify RBAC; re-run Step 5 patch | Same via `run_remote` |
| Repo missing | Clone locally | Clone on remote host |
| Background test already running (qe-aws) | Monitor log / kill PID / leave | N/A |
| Agent-started test dies immediately (qe-aws) | **Expected** — tell user to run `run-qe-aws-loadtest-background.sh` from their terminal | N/A |
| Pre-test cleanup `CLEANUP_FAILED` / webhook restart timeout | Stale webhook ReplicaSet pod during `kubectl wait` — retry with `RUN_ENV="RESTART_OPERATOR=false"` or wait for DWO healthy | Same via `run_remote` |
| k6 exit code 99 (threshold violations) | CPU/mem/ready-duration thresholds crossed — **not** necessarily DevWorkspace failures; check `devworkspace_ready_failed` in log | Same |
| Single-ns and separate-ns in different `run_*` dirs | Merge single-ns logs into report run dir before Step 12e | N/A |
| tmux session exists (perflab) | Attach / kill / leave | Same |
| tmux not installed (perflab) | N/A — qe-aws uses background script | Install on remote or fall back to `nohup` |

---

## Manual Monitoring Commands

### CRC QE AWS (local — background script, no tmux)

```bash
./scripts/run-qe-aws-loadtest-background.sh --status
tail -f outputs/loadtest_current.log
cat outputs/loadtest.meta
cat outputs/loadtest.pid && kill -0 "$(cat outputs/loadtest.pid)" && echo RUNNING
# Stop a running test (if needed):
kill "$(cat outputs/loadtest.pid)" && rm -f outputs/loadtest.pid
```

### Performance Labs (remote — SSH into perf lab instance, tmux)

```bash
ssh "${PERFLAB_USER}@${PERFLAB_HOST}" "tmux ls"
ssh -t "${PERFLAB_USER}@${PERFLAB_HOST}" "tmux attach-session -t loadtest"
ssh "${PERFLAB_USER}@${PERFLAB_HOST}" "tmux capture-pane -t loadtest -p | tail -50"
ssh "${PERFLAB_USER}@${PERFLAB_HOST}" "tmux kill-session -t loadtest"
```

---

## Session Learnings (operational reference)

### Agent vs user terminal (qe-aws)

- The **Cursor agent must not start** long-running load tests — processes die when the agent shell ends.
- **User runs** `./scripts/run-qe-aws-loadtest-background.sh` from their terminal.
- **Agent monitors** by reading `outputs/loadtest_current.log`, `outputs/loadtest.meta`, and per-test logs under `outputs/run_*/logs/`.

### Ask before acting

1. **Cluster mode** (`qe-aws` vs `perflab`) — Step 0b
2. **Test type** (controller / webhook / backup) — Step 0c
3. Never probe both clusters or auto-start tests without user selection.

### Webhook operator restart flake

- Default `RESTART_OPERATOR=true` deletes and waits for webhook pods between tests.
- Under load, **stale ReplicaSet pods** can cause `kubectl wait` timeout → `CLEANUP_FAILED` before k6 runs.
- **Workaround:** `RUN_ENV="RESTART_OPERATOR=false"` when DWO is already healthy (especially single-ns retry).
- Separate-ns test may pass restart while single-ns fails — run single-ns alone with restart disabled.

### Investigating DevWorkspace failures

| Source | Location | Use |
|--------|----------|-----|
| Failure snapshot | `outputs/run_*/logs/*_failure_report.csv` | Final failed DW rows for report (may be incomplete — overwrites every 10s) |
| DW watch log | `logs/YYYY-MM-DD_HH-MM-SS_dw_watch.log` (repo root) | Full phase transitions; find all failures including those scrolled out of failure CSV |
| Events log | `logs/YYYY-MM-DD_HH-MM-SS_events.log` | Pod mount timeouts, image pull errors |
| k6 metric | `devworkspace_ready_failed` in `*.log` | Count of VUs that saw `Failed` phase (authoritative for pass/fail count) |

Common failure modes at 1500 scale:
- **DevWorkspaceRouting `resourceVersion: 0`** — controller race under load
- **FailedMount / configmap cache timeout** — API/kubelet pressure during ramp-up

### k6 exit codes vs workspace health

- **Exit 99** — threshold violations (`operator_cpu_violations`, `ready_duration`, etc.) — test can still have **1500/1500 ready** and **0** `devworkspace_ready_failed`.
- **Exit 101** — often `teardown()` timeout during cleanup after successful run.
- Distinguish threshold failures from workspace failures when reporting to user.

### Monitoring workspace phases

```bash
OUTPUT_FILE=outputs/run_<timestamp>/dw_status.csv \
  ./scripts/track-dw-status-background.sh 10
# Or: export TRACK_DW_SCRIPT=/path/to/track_dw.sh
```

### Report and publish checklist

1. Merge logs if tests split across multiple `run_*` directories
2. `./scripts/generate-prerelease-loadtest-report.sh <run_dir> outputs/cluster_capacity_*.txt`
3. **Performance Labs only**: Copy results locally with `scp -r` — mandatory (Step 12g)
4. Share paths: `<run_dir>/loadtest_report.md` and `<run_dir>/controller_load_test_results.csv`
   - **Performance Labs**: use LOCAL paths in `${PWD}/outputs/` after Step 12g copy
   - **QE AWS**: use paths in `${REPO_DIR}/outputs/` (already local)
5. User imports CSV → Google Sheet **DevSpaces 3.29.0-RC.02.07 Load Testing Results**
6. User pastes markdown → Google Doc **DevSpaces 3.29.0-RC.02.07 Load Testing**

### Failure report CSV validation

**CRITICAL:** `*_failure_report.csv` files may contain **stale data from previous test runs** and are **not emptied between tests**. When generating markdown reports:

1. **Check actual k6 output** for `devworkspace_ready_failed` metric — this is the authoritative failure count
2. **Only include CSV data** when `devworkspace_ready_failed > 0` in the k6 log
3. **Write "None"** for tests where `devworkspace_ready_failed: 0` regardless of CSV file contents

Example detection logic:

```bash
has_failures() {
  local log_file="$1"
  local line=$(grep "devworkspace_ready_failed" "$log_file" | grep -v "^time=" | sed 's/\x1b\[[0-9;]*m//g')
  local failed_count=$(echo "$line" | sed 's/.*devworkspace_ready_failed[.:]*//g' | awk '{print $1}')
  
  if [[ "$failed_count" =~ ^[0-9]+$ ]] && [[ "$failed_count" -gt 0 ]]; then
    return 0  # Has failures - include CSV
  else
    return 1  # No failures - write "None"
  fi
}
```

**Why this matters:** Tests are often run sequentially in the same `logs/` directory. A failed test creates `50_single_20m_failure_report.csv`, then a later successful 50-workspace test reuses the same log directory but doesn't delete the old CSV. Trusting the CSV file without checking k6 metrics produces incorrect "failures" in the report for tests that actually passed.

### Webhook and backup report generation

**Webhook tests** (`generate-webhook-loadtest-report.sh`):
- k6 metrics are in the **log files**, not separate `*_metrics.txt` files
- Extract from `✓ exec forbidden for foreign workspace` to `load_test ✓` line (inclusive)
- **Stop before cleanup output** — do NOT include `🧹 Force deleting all pods` or pod deletion lines
- For failed tests: extract error context (3-10 lines) but exclude cleanup
- Structure: same as controller reports (Cluster Info, Operator Version, Test Results by user count, CSV)

**Backup tests** (`generate-backup-loadtest-report.sh`):
- k6 metrics similar to controller tests (use `devworkspace_ready_failed` for failure detection)
- **SECURITY**: Only OpenShift Internal registry permitted (external registries like quay.io NOT allowed due to past quay.io outage)
- Test plan must use `--dwoc-config-type openshift-internal` with empty `--registry-path ""`

### Backup test OpenShift internal registry bug

**Bug**: When switching from external registry (quay.io) to OpenShift internal registry, `configure-dwoc-backup.sh` must explicitly **remove** the `authSecret` field from DWOC. Kubernetes JSON merge patches do NOT delete fields when set to `null` — they ignore the null value.

**Symptom**: Backup jobs fail with `401: Unauthorized` error trying to push to quay.io instead of the internal registry, even though test plan specifies `--dwoc-config-type openshift-internal`.

**Root cause**: Previous test runs configure DWOC with:
```json
{
  "registry": {
    "authSecret": "quay-push-secret",
    "path": "quay.io/rokumar"
  }
}
```

When `apply_openshift_internal_dwoc_config()` runs, the merge patch with `"authSecret": null` doesn't remove the field — it's ignored. Backup jobs inherit the old quay.io config.

**Fix** (committed in bb6b705):
```bash
# First, explicitly remove authSecret field using JSON patch 'remove' operation
kubectl patch devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" --type json --patch '[
  {"op": "remove", "path": "/config/workspace/backupCronJob/registry/authSecret"}
]' 2>/dev/null || log_info "No authSecret field to remove"

# Then apply merge patch for the rest
kubectl patch devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" --type merge --patch '{
  "config": {
    "workspace": {
      "backupCronJob": {
        "registry": {
          "path": "image-registry.openshift-image-registry.svc:5000"
        }
      }
    }
  }
}'
```

**Verification**:
```bash
# Before fix: authSecret still present
oc get devworkspaceoperatorconfig -n openshift-operators devworkspace-operator-config \
  -o jsonpath='{.config.workspace.backupCronJob.registry}'
# Before fix (external registry): {"authSecret":"quay-push-secret","path":"quay.io/<username>"}

# After fix (OpenShift internal): authSecret removed
# Output: {"path":"image-registry.openshift-image-registry.svc:5000"}
```

**When debugging backup test failures**:
1. Check backup job pod logs: `oc logs -n <namespace> job/<job-name>`
2. Look for registry URL in "Backing up devworkspace ... to image" line
3. If shows external registry (quay.io, etc.) instead of internal → DWOC misconfigured
4. Verify DWOC: `oc get devworkspaceoperatorconfig -n openshift-operators -o jsonpath='{.config.workspace.backupCronJob.registry}'`
5. Check for `authSecret` field — should be absent for internal registry
6. Delete old backup jobs to force recreation: `oc delete jobs -n <namespace> -l devworkspace.devfile.io/backup-job=true`

**Default configuration** (as of 2026-07-05):
- All backup tests default to `openshift-internal` registry (no external registry hardcoding)
- `REGISTRY_PATH` and `REGISTRY_SECRET` default to empty strings
- `DWOC_CONFIG_TYPE` defaults to `openshift-internal`
- Extract full k6 summary from logs
- Include backup-specific metrics (ImageStreamTag success, backup wait time, restore validation)
- Structure: same as controller/webhook (Cluster Info, Operator Version, Test Results by workspace count, CSV)
- Note: backup tests use `backup_run_*` directories, not `run_*`

**k6 output extraction pattern** (webhook):
```bash
# Find start line (first check mark)
start_line=$(grep -n "exec forbidden for foreign workspace\|exec allowed for own workspace" "$log_file" | head -1 | cut -d: -f1)

# Find end line (load_test ✓)
end_line=$(sed -n "${start_line},\$p" "$log_file" | grep -n "load_test ✓" | head -1 | cut -d: -f1)

# Extract and clean (stop BEFORE cleanup lines)
sed -n "${start_line},$((start_line + end_line - 1))p" "$log_file" | sed 's/\x1b\[[0-9;]*m//g'
```

**Common mistake:** Including cleanup output (`🧹 Force deleting...`, `pod "workspace..." deleted`) in k6 metrics section — these lines appear AFTER the test completes and should never be in the report's k6 Output section.

### Key file map (qe-aws)

| File | Purpose |
|------|---------|
| `outputs/cluster_capacity_*.txt` | `kubectl get nodes` snapshot for report |
| `outputs/dwo_version_*.txt` | DWO version at test start |
| `outputs/dwoc_config_*.txt` | DevWorkspaceOperatorConfig before/after patch |
| `outputs/loadtest_current.log` | Active suite stdout (symlink) |
| `outputs/loadtest.meta` | PID, log path, plan, start time |
| `outputs/run_<ts>/logs/1500_single_ns_40m.log` | Full k6 log (not for report paste) |
| `outputs/run_<ts>/loadtest_report.md` | Documentation markdown |
| `outputs/run_<ts>/controller_load_test_results.csv` | Parsed metrics for Google Sheet |

---

- **Two separate modes** — CRC QE AWS (local `oc login`, background script) vs Performance Labs (SSH into instance, remote tmux)
- **CRC QE AWS only:** `devspaces-prerelease-test-plan.json`, custom `make test_load` args, DWO verify-only, DWOC patch via local `kubectl`
- **Performance Labs only:** SSH to `${PERFLAB_USER}@${PERFLAB_HOST}`, `controller-test-plan.json`, DWO install via `reinstall_dwo_operator.sh`
- **CRC QE AWS** uses `run-qe-aws-loadtest-background.sh` (nohup) — no tmux required; survives terminal close
- **Performance Labs** uses tmux so tests survive SSH disconnects
- `devspaces-prerelease-test-plan.json` is **CRC QE AWS only** — 1500 workspaces single namespace + 1500 separate namespaces; not used on Performance Labs
- CRC-local reduced plans (`webhook-crc-test-plan.json`, `backup-restore-crc-*`) are for local CRC only — not the 32-node QE AWS cluster
- Cluster capacity (`kubectl get nodes` allocatable CPU/memory) is captured in Step 2 and **reprinted in the final results** (Step 12a)
- DWO version (CSV, deployments, subscription) is captured in Step 4 and **reprinted in the final results** (Step 12b)
- **QE AWS:** DWO is pre-installed — verify version only; never run `reinstall_dwo_operator.sh`
- **Performance Labs:** install/reinstall DWO from testing catalog via `scripts/reinstall_dwo_operator.sh` when version is missing or wrong
- DevWorkspaceOperatorConfig is **automatically patched** in Step 5 (`imagePullPolicy: IfNotPresent`, `progressTimeout: 3600s`) — merge-patch if exists, create if missing
- DevWorkspaceOperatorConfig patch is logged to `outputs/dwoc_config_<timestamp>.txt` and reprinted in final results (Step 12c)
- After both tests finish, generate **`outputs/run_<timestamp>/controller_load_test_results.csv`** and **`outputs/run_<timestamp>/loadtest_report.md`** via `./scripts/generate-prerelease-loadtest-report.sh` — **share both paths with the user**
- **Performance Labs Step 3:** **Check remote prerequisites first** — k6 and kubectl must be installed on the SSH host before tests can run; jq is optional but recommended for JSON test plans
- **Performance Labs only (Step 12g):** **MANDATORY** — copy entire `outputs/run_<timestamp>/` directory + pre-test snapshots from remote host to local `${PWD}/outputs/` using `scp -r`; all file paths shown to user after this step must reference LOCAL copies
- **Step 12f:** Instruct user to import CSV into Google Sheet **DevSpaces 3.29.0-RC.02.07 Load Testing Results** and paste markdown into Google Doc **DevSpaces 3.29.0-RC.02.07 Load Testing**
