//
// Copyright (c) 2019-2025 Red Hat, Inc.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import http from 'k6/http';
import {sleep} from 'k6';
import {Trend, Counter, Gauge} from 'k6/metrics';
import encoding from 'k6/encoding';
import {htmlReport} from "https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js";
import {
  getDevWorkspacesFromApiServer,
  createAuthHeaders,
  detectClusterType,
  checkDevWorkspaceOperatorMetrics,
  checkEtcdMetrics,
  createFilteredSummaryData,
  formatBackupMetricsSummary,
} from '../../common/utils.js';

const inCluster = __ENV.IN_CLUSTER === 'true';
const apiServer = inCluster ? `https://kubernetes.default.svc` : __ENV.KUBE_API;
const token = inCluster ? open('/var/run/secrets/kubernetes.io/serviceaccount/token') : __ENV.KUBE_TOKEN;
const useSeparateNamespaces = __ENV.SEPARATE_NAMESPACES === "true";
const operatorNamespace = __ENV.DWO_NAMESPACE || 'openshift-operators';
const loadTestNamespace = __ENV.LOAD_TEST_NAMESPACE || "loadtest-devworkspaces";
const backupMonitorDurationMinutes = Number(__ENV.BACKUP_MONITOR_DURATION_MINUTES || 30);
const dwocConfigType = __ENV.DWOC_CONFIG_TYPE || 'correct';
const verifyRestore = __ENV.VERIFY_RESTORE !== 'false'; // Default to true, can be disabled with VERIFY_RESTORE=false
const maxRestoreSamples = Number(__ENV.MAX_RESTORE_SAMPLES || 10); // Maximum number of workspaces to restore for verification// Cron schedule for backup jobs (e.g., "*/10 * * * *")
const backupJobLabel = "controller.devfile.io/backup-job=true";
// ImageStreamTag-based backup success detection applies ONLY to openshift-internal.
// External registry modes (correct/incorrect) use ephemeral Job status — see else branch in Step 3.
const BACKUP_IMAGE_STREAM_TAG = 'latest';
const useImageStreamTagBackup = dwocConfigType === 'openshift-internal';
let ETCD_NAMESPACE = 'openshift-etcd';
let ETCD_POD_NAME_PATTERN = 'etcd';
const ETCD_POD_SELECTOR = `app=${ETCD_POD_NAME_PATTERN}`;
const OPERATOR_POD_SELECTOR = 'app.kubernetes.io/name=devworkspace-controller';

// Parse initial restart counts from environment variables
const initialEtcdRestarts = __ENV.INITIAL_ETCD_RESTARTS ? JSON.parse(__ENV.INITIAL_ETCD_RESTARTS) : {};
const initialOperatorRestarts = __ENV.INITIAL_OPERATOR_RESTARTS ? JSON.parse(__ENV.INITIAL_OPERATOR_RESTARTS) : {};

const headers = createAuthHeaders(token);

// Track backup status with a simple map
const backupStatusMap = new Map();  // devworkspace_name -> {backed_up: boolean, namespace: string, workspaceId: string}
const workspaceIdToNameMap = new Map();  // devworkspace_id -> devworkspace_name for quick lookup
const seenJobUids = new Set();  // Track which jobs we've already processed
const totalPodsCreated = new Map();  // Track cumulative pod count per job UID
const jobsPerWorkspaceId = new Map();  // workspace_id -> count of jobs created for that workspace
const permanentlyFailedJobUids = new Set();  // Track jobs that hit Failed=True condition
const completedJobUidsForDuration = new Set();  // Track jobs already recorded in backup_job_duration

export const options = {
  scenarios: {
    backup_load_test: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 1,
      maxDuration: `${backupMonitorDurationMinutes + 30}m`,
      exec: 'runBackupLoadTest',
    },
  },
  thresholds: {
    // openshift-internal: backup success is measured via ImageStreamTags, not ephemeral Jobs
    'backup_jobs_total': useImageStreamTagBackup ? [] : ['value>0'],
    'backup_jobs_succeeded': useImageStreamTagBackup || dwocConfigType === 'incorrect' ? [] : ['value>0'],
    'backup_jobs_failed': useImageStreamTagBackup ? [] : (dwocConfigType === 'incorrect' ? ['value>0'] : ['value==0']),
    'backup_pods_total': useImageStreamTagBackup ? [] : ['value>0'],
    'workspaces_stopped': ['count>0'],
    'workspaces_backed_up': dwocConfigType === 'incorrect' ? [] : ['count>0'],
    'backup_success_rate': dwocConfigType === 'incorrect' ? [] : ['value>=0.95'],
    'imagestreamtags_backed_up': useImageStreamTagBackup ? ['value>0'] : [],
    'imagestreamtags_total': useImageStreamTagBackup ? ['value>0'] : [],
    'imagestreamtag_success_rate': useImageStreamTagBackup ? ['value>=0.95'] : [],
    'imagestreams_created': useImageStreamTagBackup ? ['count>0'] : [],
    'imagestreams_expected': useImageStreamTagBackup ? ['count>0'] : [],
    // Restore thresholds only apply for correct/openshift-internal modes
    'restore_workspaces_total': dwocConfigType === 'incorrect' || !verifyRestore ? [] : ['count>0'],
    'restore_workspaces_succeeded': dwocConfigType === 'incorrect' || !verifyRestore ? [] : ['count>0'],
    'restore_workspaces_failed': dwocConfigType === 'incorrect' || !verifyRestore ? [] : ['count==0'],
    'restore_success_rate': dwocConfigType === 'incorrect' || !verifyRestore ? [] : ['value>=0.95'],
    'operator_cpu_violations': ['count==0'],
    'operator_mem_violations': ['count==0'],
  },
  insecureSkipTLSVerify: true,
};

// Metrics
const backupJobsTotal = new Gauge('backup_jobs_total');
const backupJobsSucceeded = new Gauge('backup_jobs_succeeded');
const backupJobsFailed = new Gauge('backup_jobs_failed');  // All non-succeeded, non-running jobs (legacy, less accurate)
const backupJobsPermanentlyFailed = new Gauge('backup_jobs_permanently_failed');  // Jobs with Failed=True condition
const backupJobsRunning = new Gauge('backup_jobs_running');
const backupPodsTotal = new Gauge('backup_pods_total');
const workspacesStopped = new Counter('workspaces_stopped');
const workspacesBackedUp = new Counter('workspaces_backed_up');
const backupSuccessRate = new Gauge('backup_success_rate');
const backupJobDuration = new Trend('backup_job_duration');
const backupJobsPerWorkspace = new Gauge('backup_jobs_per_workspace');  // Average jobs per workspace
const backupMaxJobsPerWorkspace = new Gauge('backup_max_jobs_per_workspace');  // Max jobs for any single workspace
// openshift-internal only: live + final summary metrics for backup ImageStreamTags
const imageStreamTagsBackedUp = new Gauge('imagestreamtags_backed_up');
const imageStreamTagsTotal = new Gauge('imagestreamtags_total');
const imageStreamTagSuccessRate = new Gauge('imagestreamtag_success_rate');
// Legacy counter names kept for CSV/log parsers (values = ImageStreamTag counts)
const imageStreamsCreated = new Counter('imagestreams_created');
const imageStreamsExpected = new Counter('imagestreams_expected');
const operatorCpu = new Trend('average_operator_cpu');
const operatorMemory = new Trend('average_operator_memory');
const etcdCpu = new Trend('average_etcd_cpu');
const etcdMemory = new Trend('average_etcd_memory');
const operatorCpuViolations = new Counter('operator_cpu_violations');
const operatorMemViolations = new Counter('operator_mem_violations');
const operatorPodRestarts = new Gauge('operator_pod_restarts_total');
const etcdPodRestarts = new Gauge('etcd_pod_restarts_total');

// Restore verification metrics
const restoreWorkspacesTotal = new Counter('restore_workspaces_total');
const restoreWorkspacesSucceeded = new Counter('restore_workspaces_succeeded');
const restoreWorkspacesFailed = new Counter('restore_workspaces_failed');
const restoreDuration = new Trend('restore_duration');
const restoreSuccessRate = new Gauge('restore_success_rate');

const maxCpuMillicores = 250;
const maxMemoryBytes = 200 * 1024 * 1024;
const registryConfig = {
  registry: __ENV.REGISTRY_URL || 'quay.io',
  username: __ENV.REGISTRY_USERNAME,
  password: __ENV.REGISTRY_PASSWORD,
  expectedArtifactType: __ENV.EXPECTED_ARTIFACT_TYPE || 'application/vnd.devworkspace.backup.v1+json'
};

export function setup() {
  const clusterInfo = detectClusterType(apiServer, headers);
  ETCD_NAMESPACE = clusterInfo.etcdNamespace;
  ETCD_POD_NAME_PATTERN = clusterInfo.etcdPodPattern;

  return {
    startTime: Date.now(),
  };
}

export function runBackupLoadTest(data) {
  console.log("\n======================================");
  console.log("Backup Load Test - Using Existing Workspaces");
  console.log("======================================\n");

  // Stop workspaces and monitor backups
  const backedUpWorkspaces = stopWorkspacesAndMonitorBackups(data);

  // Restore verification (if enabled and workspaces were backed up)
  if (verifyRestore) {
    // Don't attempt restore in incorrect mode - backups intentionally failed
    if (dwocConfigType === 'incorrect') {
      console.log("\nℹ️  Restore verification skipped - DWOC config type is 'incorrect' (backups intentionally failed)");
    } else if (backedUpWorkspaces.length > 0) {
      console.log("\n======================================");
      console.log("Restore Verification");
      console.log("======================================\n");
      verifyWorkspaceRestore(backedUpWorkspaces);
    } else {
      console.warn("\n⚠️  No workspaces were successfully backed up - skipping restore verification");
    }
  } else {
    console.log("\nℹ️  Restore verification is disabled (VERIFY_RESTORE=false)");
  }
}

// Parse cron schedule to extract interval in minutes
// Supports simple patterns like "*/N * * * *" (every N minutes)
function stopWorkspacesAndMonitorBackups(data) {
  // Step 1: Get all DevWorkspaces
  console.log("Step 1: Discovering existing DevWorkspaces...");
  const devWorkspaces = getAllDevWorkspaces();
  console.log(`Found ${devWorkspaces.length} DevWorkspaces\n`);

  if (devWorkspaces.length === 0) {
    const errorMsg = "No DevWorkspaces found. Workspaces should have been created in Phase 2.";
    console.error(errorMsg);
    throw new Error(errorMsg);
  }

  // Initialize backup tracking map
  console.log("Initializing backup tracking map...");
  for (const dw of devWorkspaces) {
    const name = dw.metadata.name;
    const namespace = dw.metadata.namespace;
    const workspaceId = dw.status && dw.status['devworkspaceId'];

    backupStatusMap.set(name, {
      backed_up: false,
      namespace: namespace,
      workspaceId: workspaceId
    });

    // Create reverse lookup map
    if (workspaceId) {
      workspaceIdToNameMap.set(workspaceId, name);
    }
  }
  console.log(`Tracking ${backupStatusMap.size} workspaces for backup\n`);

  // Step 2: Stop all workspaces
  console.log("Step 2: Stopping all DevWorkspaces...");
  const stoppedCount = stopAllDevWorkspaces(devWorkspaces);
  workspacesStopped.add(stoppedCount);
  console.log(`Stopped ${stoppedCount} DevWorkspaces\n`);

  // Wait for workspaces to actually stop
  console.log("Waiting 30 seconds for workspaces to stop...");
  sleep(30);

  if (useImageStreamTagBackup) {
    // Step 3: Monitor until each workspace has a backup ImageStreamTag (durable signal)
    console.log("\nStep 3: Monitoring backup completion via ImageStreamTags...");
    console.log(`Expecting ImageStreamTag "${BACKUP_IMAGE_STREAM_TAG}" in each workspace namespace`);
    monitorBackupCompletionWithImageStreamTags(backupMonitorDurationMinutes, 10);
  } else {
    // External registry (correct/incorrect): Job creation + Job success drive backed_up
    console.log("\nStep 3: Waiting for backup Jobs to be created...");
    console.log(`Expecting backup jobs for ${stoppedCount} stopped workspaces`);
    const jobsCreated = waitForAllBackupJobsCreation(stoppedCount, 30, 10);
    if (!jobsCreated) {
      console.warn(`⚠️  Not all backup jobs were created within timeout`);
      console.warn("Continuing to monitor anyway...\n");
    } else {
      console.log(`✅ All ${stoppedCount} backup jobs have been created\n`);
    }

    // Step 4: Monitor backup jobs and operator/etcd metrics
    console.log("\nStep 4: Monitoring backup Jobs and system metrics...");
    monitorBackupJobsAndMetrics(backupMonitorDurationMinutes);
  }

  // Step 5: Verify all workspaces were backed up
  console.log("\nStep 5: Verifying backup coverage...");
  const backedUpWorkspaces = verifyBackupCoverage(devWorkspaces);

  // Step 6: Final metrics collection
  console.log("\nStep 6: Collecting final metrics...");
  collectFinalMetrics();

  console.log("\n======================================");
  console.log("Backup Monitoring Completed");
  console.log("======================================\n");

  // Return list of backed up workspaces for restore verification
  return backedUpWorkspaces;
}

function getAllDevWorkspaces() {
  const result = getDevWorkspacesFromApiServer(apiServer, loadTestNamespace, headers, useSeparateNamespaces);

  if (result.error) {
    console.error(`Failed to get DevWorkspaces: ${result.error}`);
    return [];
  }

  return result.devWorkspaces || [];
}

function stopAllDevWorkspaces(devWorkspaces) {
  let stoppedCount = 0;

  for (const dw of devWorkspaces) {
    const namespace = dw.metadata.namespace;
    const name = dw.metadata.name;

    // Skip if already stopped
    if (!dw.spec?.started) {
      continue;
    }

    // Patch DevWorkspace to set started=false
    const patchUrl = `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${namespace}/devworkspaces/${name}`;
    const patchPayload = JSON.stringify({
      spec: {
        started: false
      }
    });

    const mergeHeaders = createAuthHeaders(token, 'application/merge-patch+json');
    const res = http.patch(patchUrl, patchPayload, {headers: mergeHeaders});

    if (res.status === 200) {
      stoppedCount++;
    } else {
      console.warn(`  Failed to stop ${namespace}/${name}: ${res.status}`);
    }
  }

  return stoppedCount;
}

function waitForAllBackupJobsCreation(expectedCount, maxWaitMinutes, pollIntervalSeconds) {
  const maxAttempts = (maxWaitMinutes * 60) / pollIntervalSeconds;
  let attempts = 0;
  const startTime = Date.now();

  console.log(`Waiting for ${expectedCount} backup jobs (max ${maxWaitMinutes} minutes)...`);

  while (attempts < maxAttempts) {
    const jobs = getBackupJobs();
    const currentCount = jobs.length;

    const elapsed = Math.floor((Date.now() - startTime) / 1000);
    const progress = ((currentCount / expectedCount) * 100).toFixed(1);

    // Log progress every 10 attempts or when count changes
    if (attempts % 10 === 0 || (attempts > 0 && currentCount !== jobs.length)) {
      console.log(`  [${elapsed}s] Backup jobs: ${currentCount}/${expectedCount} (${progress}%)`);
    }

    // Success: all jobs created
    if (currentCount >= expectedCount) {
      console.log(`  ✅ All ${expectedCount} backup jobs created after ${elapsed}s`);
      return true;
    }

    sleep(pollIntervalSeconds);
    attempts++;
  }

  // Timeout - report how many we got
  const jobs = getBackupJobs();
  const finalCount = jobs.length;
  const totalWaitTime = maxWaitMinutes * 60;
  console.log(`  ⏱️  Timeout after ${totalWaitTime}s: only ${finalCount}/${expectedCount} jobs created`);

  return false;
}

function getBackupJobs() {
  const jobsUrl = `${apiServer}/apis/batch/v1/jobs?labelSelector=${encodeURIComponent(backupJobLabel)}`;
  const res = http.get(jobsUrl, {headers});

  if (res.status !== 200) {
    console.warn(`Failed to get backup Jobs: ${res.status}`);
    return [];
  }

  const data = JSON.parse(res.body);
  return data.items || [];
}

function assertOpenShiftInternalBackupMode(caller) {
  if (!useImageStreamTagBackup) {
    throw new Error(`${caller} is only valid when DWOC_CONFIG_TYPE=openshift-internal (current: ${dwocConfigType})`);
  }
}

function getImageStreamTags(namespace) {
  assertOpenShiftInternalBackupMode('getImageStreamTags');
  const url = useSeparateNamespaces
    ? `${apiServer}/apis/image.openshift.io/v1/imagestreamtags`
    : `${apiServer}/apis/image.openshift.io/v1/namespaces/${namespace}/imagestreamtags`;

  const res = http.get(url, {headers});

  if (res.status !== 200) {
    console.warn(`Failed to get ImageStreamTags: ${res.status}`);
    return [];
  }

  const data = JSON.parse(res.body);
  return data.items || [];
}

function imageStreamTagHasImage(imageStreamTag) {
  if (imageStreamTag.image) {
    return true;
  }
  if (imageStreamTag.tag?.items?.length > 0) {
    return true;
  }
  if (imageStreamTag.status?.image) {
    return true;
  }
  return false;
}

function workspaceMatchesBackupImageStream(streamName, dwName, dwId) {
  return streamName === dwName
    || streamName === dwId
    || (dwName && streamName.includes(dwName))
    || (dwId && streamName.includes(dwId));
}

function findBackupImageStreamTag(dwName, dwId, namespace, imageStreamTags) {
  for (const tag of imageStreamTags) {
    if (tag.metadata?.namespace !== namespace) {
      continue;
    }

    const fullName = tag.metadata?.name || '';
    const colonIndex = fullName.lastIndexOf(':');
    if (colonIndex === -1) {
      continue;
    }

    const streamName = fullName.substring(0, colonIndex);
    const tagName = fullName.substring(colonIndex + 1);

    if (tagName !== BACKUP_IMAGE_STREAM_TAG) {
      continue;
    }

    if (!workspaceMatchesBackupImageStream(streamName, dwName, dwId)) {
      continue;
    }

    if (imageStreamTagHasImage(tag)) {
      return tag;
    }
  }

  return null;
}

function buildImageStreamTagsByNamespace() {
  const tagsByNamespace = new Map();

  if (useSeparateNamespaces) {
    const allTags = getImageStreamTags();
    for (const tag of allTags) {
      const namespace = tag.metadata?.namespace;
      if (!namespace) {
        continue;
      }
      if (!tagsByNamespace.has(namespace)) {
        tagsByNamespace.set(namespace, []);
      }
      tagsByNamespace.get(namespace).push(tag);
    }
    return tagsByNamespace;
  }

  tagsByNamespace.set(loadTestNamespace, getImageStreamTags(loadTestNamespace));
  return tagsByNamespace;
}

function countBackedUpWorkspaces() {
  let backedUpCount = 0;
  for (const [, info] of backupStatusMap) {
    if (info.backed_up) {
      backedUpCount++;
    }
  }
  return backedUpCount;
}

function updateBackedUpFromImageStreamTags() {
  const tagsByNamespace = buildImageStreamTagsByNamespace();
  let newlyMarked = 0;

  for (const [dwName, statusInfo] of backupStatusMap) {
    if (statusInfo.backed_up) {
      continue;
    }

    const namespaceTags = tagsByNamespace.get(statusInfo.namespace) || [];
    const backupTag = findBackupImageStreamTag(
      dwName,
      statusInfo.workspaceId,
      statusInfo.namespace,
      namespaceTags,
    );

    if (backupTag) {
      statusInfo.backed_up = true;
      backupStatusMap.set(dwName, statusInfo);
      newlyMarked++;
    }
  }

  return newlyMarked;
}

function listUnbackedWorkspaces() {
  for (const [name, info] of backupStatusMap) {
    if (!info.backed_up) {
      console.warn(`  Not backed up: ${info.namespace}/${name} (ID: ${info.workspaceId || 'unknown'})`);
    }
  }
}

function updateImageStreamTagMetrics(backedUpCount, totalCount) {
  if (!useImageStreamTagBackup) {
    return;
  }

  imageStreamTagsBackedUp.add(backedUpCount);
  imageStreamTagsTotal.add(totalCount);

  if (totalCount > 0) {
    imageStreamTagSuccessRate.add(backedUpCount / totalCount);
  }
}

function monitorBackupCompletionWithImageStreamTags(maxWaitMinutes, pollIntervalSeconds) {
  assertOpenShiftInternalBackupMode('monitorBackupCompletionWithImageStreamTags');
  const maxAttempts = (maxWaitMinutes * 60) / pollIntervalSeconds;
  let attempts = 0;
  const startTime = Date.now();
  const monitorStartTime = Date.now();

  console.log(`Waiting for ${backupStatusMap.size} backup ImageStreamTags (max ${maxWaitMinutes} minutes)...\n`);

  while (attempts < maxAttempts) {
    const newlyMarked = updateBackedUpFromImageStreamTags();
    const backedUpCount = countBackedUpWorkspaces();

    const elapsed = Math.floor((Date.now() - startTime) / 1000);
    const progress = ((backedUpCount / backupStatusMap.size) * 100).toFixed(1);

    if (attempts % 10 === 0 || newlyMarked > 0) {
      console.log(`  [${elapsed}s] ImageStreamTags: ${backedUpCount}/${backupStatusMap.size} (${progress}%)`);
    }

    if (backedUpCount === backupStatusMap.size) {
      console.log(`\n✅ All ${backupStatusMap.size} workspaces backed up via ImageStreamTag:${BACKUP_IMAGE_STREAM_TAG}`);
      break;
    }

    const secondsElapsed = Math.floor((Date.now() - monitorStartTime) / 1000);
    if (secondsElapsed % 5 === 0) {
      checkOperatorMetrics();
      checkSystemEtcdMetrics();
    }

    // Collect ephemeral Job metrics (pods, duration) for reporting; IST remains pass/fail signal
    const jobs = getBackupJobs();
    updateBackupJobMetrics(jobs, backedUpCount, { informationalOnly: true });

    sleep(pollIntervalSeconds);
    attempts++;
  }

  const finalBackedUp = countBackedUpWorkspaces();
  if (finalBackedUp < backupStatusMap.size) {
    const totalWaitTime = maxWaitMinutes * 60;
    console.warn(`\n⚠️  Timeout after ${totalWaitTime}s: only ${finalBackedUp}/${backupStatusMap.size} workspaces have backup ImageStreamTags`);
    listUnbackedWorkspaces();
  }

  console.log("\n📊 Monitoring finished");

  const finalJobs = getBackupJobs();
  updateBackupJobMetrics(finalJobs, countBackedUpWorkspaces(), { informationalOnly: true });
}

function recordJobDurations(jobs) {
  for (const job of jobs) {
    const jobUid = job.metadata?.uid;
    if (!jobUid || completedJobUidsForDuration.has(jobUid)) {
      continue;
    }

    const status = job.status || {};
    if (status.succeeded !== 1) {
      continue;
    }

    const startTime = status.startTime;
    const completionTime = status.completionTime;
    if (!startTime || !completionTime) {
      continue;
    }

    completedJobUidsForDuration.add(jobUid);
    const duration = new Date(completionTime).getTime() - new Date(startTime).getTime();
    backupJobDuration.add(duration);
  }
}

function updateBackupJobMetrics(jobs, backedUpCount, options = {}) {
  const informationalOnly = options.informationalOnly === true;
  const quietLogging = options.quietLogging === true || informationalOnly;
  let currentRunning = 0;

  for (const job of jobs) {
    const jobUid = job.metadata?.uid;
    if (!jobUid) {
      continue;
    }

    const status = job.status || {};
    const conditions = status.conditions || [];
    const labels = job.metadata?.labels || {};
    const workspaceId = labels['controller.devfile.io/devworkspace_id'];

    if (!seenJobUids.has(jobUid)) {
      seenJobUids.add(jobUid);
      if (workspaceId) {
        const currentCount = jobsPerWorkspaceId.get(workspaceId) || 0;
        jobsPerWorkspaceId.set(workspaceId, currentCount + 1);
      }
    }

    const activePods = status.active || 0;
    const succeededPods = status.succeeded || 0;
    const failedPods = status.failed || 0;
    const jobPodCount = activePods + succeededPods + failedPods;

    const previousMaxPods = totalPodsCreated.get(jobUid) || 0;
    if (jobPodCount > previousMaxPods) {
      totalPodsCreated.set(jobUid, jobPodCount);
    }

    if (conditions.some && conditions.some(c => c.type === 'Failed' && c.status === 'True')) {
      if (!permanentlyFailedJobUids.has(jobUid)) {
        permanentlyFailedJobUids.add(jobUid);
      }
    } else if (status.succeeded !== 1 && (status.active || 0) > 0) {
      currentRunning++;
    }
  }

  const totalJobsSeen = seenJobUids.size;
  const totalPermanentlyFailedJobs = permanentlyFailedJobUids.size;
  const totalSucceededJobs = countJobSucceededBackups(jobs);
  const totalFailedJobs = Math.max(0, totalJobsSeen - totalSucceededJobs - currentRunning);

  let cumulativePodCount = 0;
  for (const count of totalPodsCreated.values()) {
    cumulativePodCount += count;
  }

  let maxJobsForAnyWorkspace = 0;
  let avgJobsPerWorkspace = 0;
  const totalWorkspacesWithJobs = jobsPerWorkspaceId.size;

  if (totalWorkspacesWithJobs > 0) {
    let totalJobsAcrossWorkspaces = 0;
    for (const count of jobsPerWorkspaceId.values()) {
      totalJobsAcrossWorkspaces += count;
      if (count > maxJobsForAnyWorkspace) {
        maxJobsForAnyWorkspace = count;
      }
    }
    avgJobsPerWorkspace = totalJobsAcrossWorkspaces / totalWorkspacesWithJobs;
  }

  backupJobsTotal.add(totalJobsSeen);
  backupJobsSucceeded.add(totalSucceededJobs);
  backupJobsFailed.add(totalFailedJobs);
  backupJobsPermanentlyFailed.add(totalPermanentlyFailedJobs);
  backupJobsRunning.add(currentRunning);
  backupPodsTotal.add(cumulativePodCount);
  backupJobsPerWorkspace.add(avgJobsPerWorkspace);
  backupMaxJobsPerWorkspace.add(maxJobsForAnyWorkspace);

  if (!informationalOnly && totalJobsSeen > 0) {
    backupSuccessRate.add(totalSucceededJobs / totalJobsSeen);
  }

  recordJobDurations(jobs);

  if (!quietLogging) {
    console.log(
      `Jobs: total=${totalJobsSeen}, ` +
      `succeeded=${totalSucceededJobs}, ` +
      `failed=${totalFailedJobs} (perm=${totalPermanentlyFailedJobs}), ` +
      `running=${currentRunning}, ` +
      `pods=${cumulativePodCount}, ` +
      `backedUp=${backedUpCount}/${backupStatusMap.size}, ` +
      `jobs/ws=${avgJobsPerWorkspace.toFixed(2)} (max=${maxJobsForAnyWorkspace})`,
    );
  }
}

function countJobSucceededBackups(jobs) {
  let succeeded = 0;
  for (const job of jobs) {
    if (job.status?.succeeded === 1) {
      succeeded++;
    }
  }
  return succeeded;
}

function markWorkspacesBackedUpFromJobs(jobs) {
  for (const job of jobs) {
    if (job.status?.succeeded !== 1) {
      continue;
    }

    const workspaceId = job.metadata?.labels?.['controller.devfile.io/devworkspace_id'];
    if (!workspaceId || !workspaceIdToNameMap.has(workspaceId)) {
      continue;
    }

    const dwName = workspaceIdToNameMap.get(workspaceId);
    const statusInfo = backupStatusMap.get(dwName);

    if (statusInfo && !statusInfo.backed_up) {
      statusInfo.backed_up = true;
      backupStatusMap.set(dwName, statusInfo);
      console.log(`  ✅ Backup completed for: ${statusInfo.namespace}/${dwName}`);
    }
  }
}

function monitorBackupJobsAndMetrics(durationMinutes) {
  const endTime = Date.now() + (durationMinutes * 60 * 1000);
  const pollInterval = 1; // Poll every 1 second as requested
  const monitorStartTime = Date.now();

  console.log("\nMonitoring backup jobs (map-based tracking)...\n");
  console.log(`Tracking ${backupStatusMap.size} workspaces for backup completion\n`);

  while (Date.now() < endTime) {
    const jobs = getBackupJobs();
    markWorkspacesBackedUpFromJobs(jobs);
    const backedUpCount = countBackedUpWorkspaces();
    updateBackupJobMetrics(jobs, backedUpCount);

    if (backedUpCount === backupStatusMap.size) {
      console.log("\n✅ All workspaces backed up!");
      break;
    }

    const currentRunning = jobs.filter(job => {
      const status = job.status || {};
      return status.succeeded !== 1
        && !(status.conditions || []).some(c => c.type === 'Failed' && c.status === 'True')
        && (status.active || 0) > 0;
    }).length;

    if (currentRunning === 0 && seenJobUids.size === backupStatusMap.size) {
      if (backedUpCount < backupStatusMap.size) {
        console.warn(`\n⚠️ All jobs completed but only ${backedUpCount}/${backupStatusMap.size} workspaces backed up`);
      }
      break;
    }

    const secondsElapsed = Math.floor((Date.now() - monitorStartTime) / 1000);
    if (secondsElapsed % 5 === 0) {
      checkOperatorMetrics();
      checkSystemEtcdMetrics();
    }

    sleep(pollInterval);
  }

  console.log("\n📊 Monitoring finished");
}

function verifyBackupCoverage(devWorkspaces) {
  // Use backup status map to determine which workspaces were backed up
  const backedUpWorkspaces = [];
  let backedUpCount = 0;

  for (const dw of devWorkspaces) {
    const name = dw.metadata.name;
    const namespace = dw.metadata.namespace;
    const statusInfo = backupStatusMap.get(name);

    if (statusInfo && statusInfo.backed_up) {
      backedUpCount++;
      backedUpWorkspaces.push({
        name: name,
        namespace: namespace,
        workspaceId: statusInfo.workspaceId,
        originalSpec: dw.spec,
        originalLabels: dw.metadata.labels,
      });
    }
  }

  workspacesBackedUp.add(backedUpCount);

  console.log(`Backup Coverage: ${backedUpCount}/${devWorkspaces.length} workspaces backed up`);

  if (backedUpCount < devWorkspaces.length) {
    console.warn(`Warning: ${devWorkspaces.length - backedUpCount} workspaces were not backed up`);

    // List workspaces that weren't backed up
    for (const [name, info] of backupStatusMap) {
      if (!info.backed_up) {
        console.warn(`  Not backed up: ${info.namespace}/${name} (ID: ${info.workspaceId || 'unknown'})`);
      }
    }
  }

  if (useImageStreamTagBackup) {
    verifyBackupImageStreamTags(devWorkspaces);
  }

  return backedUpWorkspaces;
}

function verifyBackupImageStreamTags(devWorkspaces) {
  assertOpenShiftInternalBackupMode('verifyBackupImageStreamTags');
  console.log("\nVerifying backup ImageStreamTags for OpenShift internal registry...");
  const tagsByNamespace = buildImageStreamTagsByNamespace();

  let imageStreamTagCount = 0;

  for (const dw of devWorkspaces) {
    const dwName = dw.metadata.name;
    const dwId = dw.status && dw.status['devworkspaceId'];
    const namespace = dw.metadata.namespace;
    const namespaceTags = tagsByNamespace.get(namespace) || [];
    const backupTag = findBackupImageStreamTag(dwName, dwId, namespace, namespaceTags);

    if (backupTag) {
      imageStreamTagCount++;
    } else {
      console.warn(`  ⚠️  No backup ImageStreamTag found for ${namespace}/${dwName} (ID: ${dwId || 'unknown'})`);
    }
  }

  imageStreamsCreated.add(imageStreamTagCount);
  imageStreamsExpected.add(devWorkspaces.length);

  console.log(`\nImageStreamTag Coverage: ${imageStreamTagCount}/${devWorkspaces.length} (tag: ${BACKUP_IMAGE_STREAM_TAG})`);

  if (imageStreamTagCount < devWorkspaces.length) {
    console.warn(`Warning: ${devWorkspaces.length - imageStreamTagCount} backup ImageStreamTags are missing`);
  }
}

function collectFinalMetrics() {
  let backedUpCount = 0;
  for (const [, info] of backupStatusMap) {
    if (info.backed_up) {
      backedUpCount++;
    }
  }

  if (useImageStreamTagBackup) {
    updateImageStreamTagMetrics(backedUpCount, backupStatusMap.size);
    const jobs = getBackupJobs();
    updateBackupJobMetrics(jobs, backedUpCount, { informationalOnly: true });
    recordJobDurations(jobs);

    console.log("\n======================================");
    console.log("Final Backup Metrics (ImageStreamTags)");
    console.log("======================================");
    console.log(`ImageStreamTags (${BACKUP_IMAGE_STREAM_TAG}): ${backedUpCount}/${backupStatusMap.size}`);
    if (backupStatusMap.size > 0) {
      const successRate = ((backedUpCount / backupStatusMap.size) * 100).toFixed(2);
      console.log(`Backup Success Rate: ${successRate}%`);
      backupSuccessRate.add(backedUpCount / backupStatusMap.size);
    }

    let cumulativePodCount = 0;
    for (const count of totalPodsCreated.values()) {
      cumulativePodCount += count;
    }
    console.log(`Backup Jobs Seen (informational): ${seenJobUids.size}`);
    console.log(`Backup Pods (informational): ${cumulativePodCount}`);
    console.log("======================================\n");
    return;
  }

  // External registry modes: report ephemeral Job metrics
  const jobs = getBackupJobs();

  // Calculate job stats
  let succeededJobs = 0;
  let failedJobs = 0;
  let runningJobs = 0;

  for (const job of jobs) {
    const status = job.status || {};
    const conditions = status.conditions || [];

    if (status.succeeded === 1) {
      succeededJobs++;
    } else if (conditions.some && conditions.some(c => c.type === 'Failed' && c.status === 'True')) {
      failedJobs++;
    } else {
      runningJobs++;
    }
  }

  // Calculate total pods
  let cumulativePodCount = 0;
  for (const count of totalPodsCreated.values()) {
    cumulativePodCount += count;
  }

  const totalJobsSeen = seenJobUids.size;

  // Calculate jobs per workspace metrics
  let totalWorkspacesWithJobs = jobsPerWorkspaceId.size;
  let maxJobsForAnyWorkspace = 0;
  let avgJobsPerWorkspace = 0;

  if (totalWorkspacesWithJobs > 0) {
    let totalJobsAcrossWorkspaces = 0;
    for (const count of jobsPerWorkspaceId.values()) {
      totalJobsAcrossWorkspaces += count;
      if (count > maxJobsForAnyWorkspace) {
        maxJobsForAnyWorkspace = count;
      }
    }
    avgJobsPerWorkspace = totalJobsAcrossWorkspaces / totalWorkspacesWithJobs;
  }

  console.log("\n======================================");
  console.log("Final Backup Job Metrics");
  console.log("======================================");
  console.log(`Total Jobs Seen: ${totalJobsSeen}`);
  console.log(`Currently Tracked Jobs: ${jobs.length} (may be less due to K8s garbage collection)`);
  console.log(`Succeeded Jobs: ${succeededJobs}`);
  console.log(`Failed Jobs (hit backOffLimit): ${failedJobs}`);
  console.log(`Running/Pending Jobs: ${runningJobs}`);
  console.log(`Total Pods Created: ${cumulativePodCount}`);
  console.log(`Workspaces Backed Up: ${backedUpCount}/${backupStatusMap.size}`);
  console.log(`Average Jobs per Workspace: ${avgJobsPerWorkspace.toFixed(2)}`);
  console.log(`Max Jobs for Any Workspace: ${maxJobsForAnyWorkspace}`);

  if (backupStatusMap.size > 0) {
    const successRate = ((backedUpCount / backupStatusMap.size) * 100).toFixed(2);
    console.log(`Backup Success Rate: ${successRate}%`);
  }
  console.log("======================================\n");

  // Show details of permanently failed jobs
  const failedJobsList = jobs.filter(job => {
    const conditions = job.status?.conditions || [];
    return conditions.some && conditions.some(c => c.type === 'Failed' && c.status === 'True');
  });

  if (failedJobsList.length > 0) {
    console.log("Failed Jobs Details:");
    for (const job of failedJobsList) {
      const conditions = job.status?.conditions || [];
      const failedCondition = conditions.find(c => c.type === 'Failed' && c.status === 'True');

      const namespace = job.metadata.namespace;
      const name = job.metadata.name;
      const podFailures = job.status?.failed || 0;
      const reason = failedCondition.reason || 'Unknown';
      const message = failedCondition.message || 'No message';

      console.log(`  ❌ ${namespace}/${name}`);
      console.log(`     Pod failures: ${podFailures}, Reason: ${reason}`);
      console.log(`     Message: ${message}`);

      // Capture and print pod logs for failed backup job
      captureBackupJobPodLogs(namespace, name);
    }
    console.log("");
  }

  // Calculate backup job durations for any jobs still in the API
  recordJobDurations(jobs);
}

function checkOperatorMetrics() {
  const metrics = {
    operatorCpu,
    operatorMemory,
    operatorCpuViolations,
    operatorMemViolations,
  };
  checkDevWorkspaceOperatorMetrics(apiServer, headers, operatorNamespace, maxCpuMillicores, maxMemoryBytes, metrics, operatorPodRestarts, OPERATOR_POD_SELECTOR, initialOperatorRestarts);
}

function checkSystemEtcdMetrics() {
  const metrics = {
    etcdCpu,
    etcdMemory,
  };
  checkEtcdMetrics(apiServer, headers, ETCD_NAMESPACE, ETCD_POD_NAME_PATTERN, metrics, etcdPodRestarts, ETCD_POD_SELECTOR, initialEtcdRestarts);
}

function ensureRegistrySecretInNamespace(namespace) {
  const secretName = 'quay-push-secret';

  // Delete existing secret if present (to ensure fresh credentials)
  const deleteUrl = `${apiServer}/api/v1/namespaces/${namespace}/secrets/${secretName}`;
  http.del(deleteUrl, null, {headers});

  // Get secret from operator namespace
  const secretUrl = `${apiServer}/api/v1/namespaces/${operatorNamespace}/secrets/${secretName}`;
  const secretRes = http.get(secretUrl, {headers});

  if (secretRes.status !== 200) {
    console.warn(`  ⚠️  Registry secret not found in ${operatorNamespace}, restore may fail`);
    return false;
  }

  // Copy secret to workspace namespace
  const secret = JSON.parse(secretRes.body);
  secret.metadata.namespace = namespace;
  delete secret.metadata.resourceVersion;
  delete secret.metadata.uid;
  delete secret.metadata.creationTimestamp;

  const createUrl = `${apiServer}/api/v1/namespaces/${namespace}/secrets`;
  const createRes = http.post(createUrl, JSON.stringify(secret), {headers});

  if (createRes.status !== 201) {
    console.warn(`  ⚠️  Failed to create registry secret in ${namespace} (HTTP ${createRes.status})`);
    return false;
  }

  return true;
}

function captureBackupJobPodLogs(jobNamespace, jobName) {
  try {
    // Get pods for the failed backup job
    const podListUrl = `${apiServer}/api/v1/namespaces/${jobNamespace}/pods?labelSelector=job-name=${jobName}`;
    const podListRes = http.get(podListUrl, {headers});

    if (podListRes.status !== 200) {
      console.log(`     [DEBUG] Failed to get pod list: HTTP ${podListRes.status}`);
      return;
    }

    const pods = JSON.parse(podListRes.body).items;
    if (pods.length === 0) {
      console.log(`     [DEBUG] No pods found for job (may be deleted already)`);
      return;
    }

    // Get logs from the most recent pod (last in the list, usually most recent attempt)
    const pod = pods[pods.length - 1];
    const podName = pod.metadata.name;
    console.log(`     [DEBUG] Found backup job pod: ${podName}`);

    // Try to get pod logs (backup jobs typically use a single container)
    const logUrl = `${apiServer}/api/v1/namespaces/${jobNamespace}/pods/${podName}/log?tailLines=30`;
    const logRes = http.get(logUrl, {headers});

    if (logRes.status === 200) {
      const logs = logRes.body.split('\n').filter(l => l.trim());
      console.log(`\n     --- Backup Job Pod Logs for ${jobNamespace}/${jobName} ---`);
      logs.forEach(line => console.log(`     ${line}`));
      console.log(`     --- End Backup Job Pod Logs ---\n`);
    } else {
      console.log(`     [DEBUG] Failed to get logs: HTTP ${logRes.status}`);

      // Try to get pod status for additional context
      const podPhase = pod.status?.phase || 'Unknown';
      const containerStatuses = pod.status?.containerStatuses || [];

      console.log(`     [DEBUG] Pod phase: ${podPhase}`);

      if (containerStatuses.length > 0) {
        const container = containerStatuses[0];
        if (container.state?.terminated) {
          console.log(`     [DEBUG] Container terminated - Reason: ${container.state.terminated.reason || 'Unknown'}`);
          if (container.state.terminated.message) {
            console.log(`     Termination message: ${container.state.terminated.message}`);
          }
          console.log(`     Exit code: ${container.state.terminated.exitCode || 'Unknown'}`);
        } else if (container.state?.waiting) {
          console.log(`     [DEBUG] Container waiting - Reason: ${container.state.waiting.reason || 'Unknown'}`);
          if (container.state.waiting.message) {
            console.log(`     Waiting message: ${container.state.waiting.message}`);
          }
        }
      }
    }
  } catch (err) {
    console.log(`     [ERROR] Exception in captureBackupJobPodLogs: ${err.message}`);
  }
}

function captureRestoreFailureLogs(namespace, workspaceName) {
  try {
    // Get pod for the failed workspace
    const podListUrl = `${apiServer}/api/v1/namespaces/${namespace}/pods?labelSelector=controller.devfile.io/devworkspace_name=${workspaceName}`;
    const podListRes = http.get(podListUrl, {headers});

    if (podListRes.status !== 200) {
      console.log(`[DEBUG] Failed to get pod list: HTTP ${podListRes.status}`);
      return;
    }

    const pods = JSON.parse(podListRes.body).items;
    if (pods.length === 0) {
      console.log(`[DEBUG] Pod not found (may be deleted already)`);
      return;
    }

    const podName = pods[0].metadata.name;
    console.log(`[DEBUG] Found pod: ${podName}`);

    // Try to get restore initContainer logs
    const logUrl = `${apiServer}/api/v1/namespaces/${namespace}/pods/${podName}/log?container=devworkspace-backup-restore&tailLines=20`;
    const logRes = http.get(logUrl, {headers});

    if (logRes.status === 200) {
      const logs = logRes.body.split('\n').filter(l => l.trim());
      console.log(`\n--- Restore Logs for ${namespace}/${workspaceName} ---`);
      logs.forEach(line => console.log(line));
      console.log(`--- End Restore Logs ---\n`);
    } else {
      console.log(`[DEBUG] Failed to get logs: HTTP ${logRes.status}`);

      // Try to get pod status for additional context
      const podUrl = `${apiServer}/api/v1/namespaces/${namespace}/pods/${podName}`;
      const podRes = http.get(podUrl, {headers});
      if (podRes.status === 200) {
        const pod = JSON.parse(podRes.body);
        const initContainers = pod.status?.initContainerStatuses || [];
        const restoreContainer = initContainers.find(c => c.name === 'devworkspace-backup-restore');
        if (restoreContainer) {
          console.log(`[DEBUG] Container state: ${JSON.stringify(restoreContainer.state)}`);
          if (restoreContainer.state?.terminated?.message) {
            console.log(`Termination: ${restoreContainer.state.terminated.message}`);
          }
        }
      }
    }
  } catch (err) {
    console.log(`[ERROR] Exception in captureRestoreFailureLogs: ${err.message}`);
  }
}

function verifyWorkspaceRestore(backedUpWorkspaces) {
  console.log(`Starting restore verification for ${backedUpWorkspaces.length} backed up workspaces`);

  const maxRestoreCount = Math.min(maxRestoreSamples, backedUpWorkspaces.length);
  const samplesToRestore = backedUpWorkspaces.slice(0, maxRestoreCount);

  console.log(`Restoring ${samplesToRestore.length} workspaces IN PARALLEL...\n`);

  // STEP 0: Ensure registry secrets (in parallel for unique namespaces)
  const uniqueNamespaces = [...new Set(samplesToRestore.map(ws => ws.namespace))];
  uniqueNamespaces.forEach(ns => ensureRegistrySecretInNamespace(ns));

  // STEP 1: Delete all workspaces in parallel using http.batch()
  console.log(`\nStep 1: Deleting ${samplesToRestore.length} workspaces in parallel...`);
  const deleteRequests = samplesToRestore.map(ws => ({
    method: 'DELETE',
    url: `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${ws.namespace}/devworkspaces/${ws.name}`,
    params: { headers }
  }));

  http.batch(deleteRequests);
  sleep(5);

  // STEP 2: Create all workspaces in parallel
  console.log(`\nStep 2: Creating ${samplesToRestore.length} restored workspaces in parallel...`);
  const createRequests = samplesToRestore.map(workspace => {
    const restoreSpec = JSON.parse(JSON.stringify(workspace.originalSpec));
    if (!restoreSpec.template) restoreSpec.template = {};
    if (!restoreSpec.template.attributes) restoreSpec.template.attributes = {};
    restoreSpec.template.attributes['controller.devfile.io/restore-workspace'] = 'true';

    // Remove projects to avoid git clone overwriting restore
    if (restoreSpec.template.projects) delete restoreSpec.template.projects;
    restoreSpec.started = true;

    // Preserve original labels to ensure cleanup finds these workspaces
    const metadata = {
      name: workspace.name,
      namespace: workspace.namespace
    };
    if (workspace.originalLabels) {
      metadata.labels = workspace.originalLabels;
    }

    return {
      method: 'POST',
      url: `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${workspace.namespace}/devworkspaces`,
      body: JSON.stringify({
        apiVersion: 'workspace.devfile.io/v1alpha2',
        kind: 'DevWorkspace',
        metadata: metadata,
        spec: restoreSpec
      }),
      params: { headers }
    };
  });

  const createResponses = http.batch(createRequests);
  samplesToRestore.forEach(() => restoreWorkspacesTotal.add(1));

  // STEP 3: Poll all workspaces in parallel until Ready
  console.log(`\nStep 3: Monitoring ${samplesToRestore.length} workspaces in parallel...`);
  const startTime = Date.now();
  const maxWaitTime = 600 * 1000;
  const pollInterval = 5 * 1000;

  const status = samplesToRestore.map(ws => ({
    ...ws,
    phase: 'Unknown',
    done: false,
    startTime: Date.now()
  }));

  let successCount = 0;
  let failCount = 0;

  while (Date.now() - startTime < maxWaitTime && status.some(s => !s.done)) {
    const statusRequests = status
      .filter(s => !s.done)
      .map(ws => ({
        method: 'GET',
        url: `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${ws.namespace}/devworkspaces/${ws.name}`,
        params: { headers }
      }));

    if (statusRequests.length === 0) break;

    const statusResponses = http.batch(statusRequests);

    let activeIdx = 0;
    status.forEach((ws, idx) => {
      if (ws.done) return;

      const res = statusResponses[activeIdx++];
      if (res.status === 200) {
        const dw = JSON.parse(res.body);
        const phase = dw.status?.phase || 'Unknown';
        status[idx].phase = phase;

        if (phase === 'Running') {
          status[idx].done = true;
          const duration = Date.now() - ws.startTime;
          restoreDuration.add(duration);
          successCount++;
          restoreWorkspacesSucceeded.add(1);
        } else if (phase === 'Failed') {
          status[idx].done = true;
          failCount++;
          restoreWorkspacesFailed.add(1);
          const failureMessage = dw.status?.message || 'No error message available';
          console.log(`\n❌ RESTORE FAILED: ${ws.namespace}/${ws.name}`);
          console.log(`   Reason: ${failureMessage}`);
          captureRestoreFailureLogs(ws.namespace, ws.name);
        }
      }
    });

    sleep(pollInterval / 1000);
  }

  // Handle timeouts
  status.forEach(ws => {
    if (!ws.done) {
      failCount++;
      restoreWorkspacesFailed.add(1);
      console.log(`\n❌ RESTORE TIMEOUT: ${ws.namespace}/${ws.name} (phase: ${ws.phase})`);
      captureRestoreFailureLogs(ws.namespace, ws.name);
    }
  });

  const successRate = samplesToRestore.length > 0 ? (successCount / samplesToRestore.length) : 0;
  restoreSuccessRate.add(successRate);

  console.log("\n======================================");
  console.log("Restore Verification Summary");
  console.log("======================================");
  console.log(`Total: ${samplesToRestore.length}`);
  console.log(`Succeeded: ${successCount}`);
  console.log(`Failed: ${failCount}`);
  console.log(`Success Rate: ${(successRate * 100).toFixed(2)}%`);
  console.log("======================================\n");
}

export function handleSummary(data) {
  const jobMetrics = [
    'backup_jobs_total',
    'backup_jobs_succeeded',
    'backup_jobs_failed',
    'backup_jobs_permanently_failed',
    'backup_jobs_running',
    'backup_pods_total',
    'backup_jobs_per_workspace',
    'backup_max_jobs_per_workspace',
    'backup_job_duration',
  ];

  const imageStreamTagMetrics = [
    'imagestreamtags_backed_up',
    'imagestreamtags_total',
    'imagestreamtag_success_rate',
    'imagestreams_created',
    'imagestreams_expected',
  ];

  const commonMetrics = [
    'workspaces_stopped',
    'workspaces_backed_up',
    'backup_success_rate',
    'restore_workspaces_total',
    'restore_workspaces_succeeded',
    'restore_workspaces_failed',
    'restore_duration',
    'restore_success_rate',
    'operator_cpu_violations',
    'operator_mem_violations',
    'average_operator_cpu',
    'average_operator_memory',
    'operator_pod_restarts_total',
    'etcd_pod_restarts_total',
    'average_etcd_cpu',
    'average_etcd_memory',
  ];

  const allowedMetrics = useImageStreamTagBackup
    ? [...commonMetrics, ...imageStreamTagMetrics, ...jobMetrics]
    : [...commonMetrics, ...jobMetrics];

  const filteredData = createFilteredSummaryData(data, allowedMetrics);

  let backupLoadTestSummaryReport = {
    stdout: formatBackupMetricsSummary(filteredData, {
      useImageStreamTagBackup,
      verifyRestore,
    }),
  };

  if (!inCluster) {
    backupLoadTestSummaryReport['backup-load-test-report.html'] = htmlReport(filteredData, {
      title: 'DevWorkspace Backup Load Test Report',
    });
  }

  return backupLoadTestSummaryReport;
}
