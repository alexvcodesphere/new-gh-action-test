// =============================================================================
// Codesphere Deploy Action — main.js
// https://github.com/codesphere-cloud/gh-action-deploy
//
// Manages workspace lifecycle using the Codesphere REST API directly.
// Zero external dependencies — uses only Node.js built-in modules.
//
// API docs: https://codesphere.com/api/scalar-ui/
// =============================================================================

const https = require("https");
const http = require("http");
const fs = require("fs");

// ---------------------------------------------------------------------------
// Load GitHub event payload (contains PR number, action, etc.)
// ---------------------------------------------------------------------------
let ghEvent = {};
try {
  const eventPath = process.env.GITHUB_EVENT_PATH;
  if (eventPath) {
    ghEvent = JSON.parse(fs.readFileSync(eventPath, "utf8"));
  }
} catch {
  // Not running in GitHub Actions — that's fine for local testing
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
const config = {
  apiUrl: process.env.INPUT_APIURL || "https://codesphere.com/api",
  token: process.env.INPUT_TOKEN,
  teamId: parseInt(process.env.INPUT_TEAMID, 10),
  planId: parseInt(process.env.INPUT_PLANID || "8", 10),
  envVars: process.env.INPUT_ENV || "",
  vpnConfig: process.env.INPUT_VPNCONFIG || "",
  branch: process.env.INPUT_BRANCH || "",
  stages: (process.env.INPUT_STAGES || "prepare run").split(/\s+/).filter(Boolean),

  // GitHub context
  repoUrl: `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}.git`,
  repository: process.env.GITHUB_REPOSITORY || "",
  eventName: process.env.GITHUB_EVENT_NAME || "",
  prAction: ghEvent.action || "",
  prNumber: String(ghEvent.number || ""),
  headRef: process.env.GITHUB_HEAD_REF || "",
  refName: process.env.GITHUB_REF_NAME || "main",
};

// ---------------------------------------------------------------------------
// Workspace naming — SINGLE SOURCE OF TRUTH
// Format: "<repo-name>-#<pr-number>" (e.g. "my-app-#42")
// ---------------------------------------------------------------------------
function workspaceName() {
  const repo = config.repository.split("/").pop();
  return `${repo}-#${config.prNumber}`;
}

// ---------------------------------------------------------------------------
// Target branch resolution
// ---------------------------------------------------------------------------
function resolveBranch() {
  if (config.branch) return config.branch;
  return config.headRef || config.refName;
}

// ---------------------------------------------------------------------------
// Parse env vars from multiline "KEY=VALUE" input
// ---------------------------------------------------------------------------
function parseEnvVars(input) {
  if (!input.trim()) return [];
  return input
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && line.includes("="))
    .map((line) => {
      const idx = line.indexOf("=");
      return { name: line.slice(0, idx), value: line.slice(idx + 1) };
    });
}

// ---------------------------------------------------------------------------
// HTTP client for the Codesphere API
// ---------------------------------------------------------------------------
function api(method, path, body = null) {
  return new Promise((resolve, reject) => {
    // Ensure apiUrl has no trailing slash, path has a leading slash
    const base = config.apiUrl.replace(/\/+$/, "");
    const fullPath = path.startsWith("/") ? path : `/${path}`;
    const url = new URL(`${base}${fullPath}`);
    const transport = url.protocol === "https:" ? https : http;

    const options = {
      method,
      hostname: url.hostname,
      port: url.port,
      path: url.pathname + url.search,
      headers: {
        Authorization: `Bearer ${config.token}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
    };

    const req = transport.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try {
            resolve(data ? JSON.parse(data) : null);
          } catch {
            resolve(data);
          }
        } else {
          const msg = `API ${method} ${path} returned ${res.statusCode}: ${data}`;
          reject(new Error(msg));
        }
      });
    });

    req.on("error", reject);

    if (body) {
      req.write(JSON.stringify(body));
    }
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Workspace API functions
// ---------------------------------------------------------------------------

async function listWorkspaces() {
  return api("GET", `/workspaces/team/${config.teamId}`);
}

async function findWorkspace() {
  const name = workspaceName();
  console.log(`🔍 Looking for workspace '${name}'...`);

  const workspaces = await listWorkspaces();
  const match = workspaces.find((ws) => ws.name === name);

  if (match) {
    console.log(`  Found: id=${match.id}, name=${match.name}`);
  }
  return match || null;
}

async function createWorkspace(branch) {
  const name = workspaceName();
  console.log(`🚀 Creating workspace '${name}'...`);

  const body = {
    teamId: config.teamId,
    name,
    planId: config.planId,
    isPrivateRepo: true,
    replicas: 1,
    gitUrl: config.repoUrl,
    initialBranch: branch,
  };

  const envVars = parseEnvVars(config.envVars);
  if (envVars.length > 0) {
    body.env = envVars;
  }

  if (config.vpnConfig) {
    body.vpnConfig = config.vpnConfig;
  }

  const workspace = await api("POST", "/workspaces", body);
  console.log(`  Created: id=${workspace.id}`);
  return workspace;
}

async function deleteWorkspace(workspaceId) {
  console.log(`🗑️  Deleting workspace ${workspaceId}...`);
  await api("DELETE", `/workspaces/${workspaceId}`);
}

async function getWorkspaceStatus(workspaceId) {
  return api("GET", `/workspaces/${workspaceId}/status`);
}

async function waitForRunning(workspaceId, timeoutMs = 300000) {
  console.log(`  ⏰ Waiting for workspace to be running...`);
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    const status = await getWorkspaceStatus(workspaceId);
    if (status.isRunning) {
      console.log(`  ✅ Workspace is running.`);
      return;
    }
    await sleep(5000);
  }

  throw new Error(`Workspace ${workspaceId} did not become running within ${timeoutMs / 1000}s`);
}

async function gitPull(workspaceId, branch) {
  console.log(`  📥 Pulling branch '${branch}'...`);
  await api("POST", `/workspaces/${workspaceId}/git/pull/origin/${branch}`);
  console.log(`  ✅ Git pull completed.`);
}

async function setEnvVars(workspaceId, vars) {
  if (vars.length === 0) return;
  console.log(`  🔧 Setting ${vars.length} environment variable(s)...`);
  await api("PUT", `/workspaces/${workspaceId}/env-vars`, vars);
}

// ---------------------------------------------------------------------------
// Pipeline execution
// ---------------------------------------------------------------------------

async function getPipelineStatus(workspaceId, stage) {
  return api("GET", `/workspaces/${workspaceId}/pipeline/${stage}`);
}

async function startPipelineStage(workspaceId, stage) {
  await api("POST", `/workspaces/${workspaceId}/pipeline/${stage}/start`);
}

async function runPipeline(workspaceId, stages) {
  if (stages.length === 0) {
    console.log("  ⏭️  No pipeline stages to run.");
    return;
  }

  console.log(`🔧 Running pipeline stages: ${stages.join(" → ")}...`);

  for (const stage of stages) {
    console.log(`  ▶ Starting '${stage}'...`);
    await startPipelineStage(workspaceId, stage);

    // 'run' stage is fire-and-forget — don't wait for it
    if (stage === "run") {
      console.log(`  ✅ '${stage}' triggered (running).`);
      continue;
    }

    // Poll until the stage completes
    const timeoutMs = 1800000; // 30 minutes
    const start = Date.now();

    while (Date.now() - start < timeoutMs) {
      const status = await getPipelineStatus(workspaceId, stage);

      if (status.status === "success" || status.state === "success") {
        console.log(`  ✅ '${stage}' completed.`);
        break;
      }

      if (status.status === "failed" || status.state === "failed" || status.status === "error") {
        throw new Error(`Pipeline stage '${stage}' failed.`);
      }

      await sleep(5000);
    }
  }
}

// ---------------------------------------------------------------------------
// GitHub Actions output
// ---------------------------------------------------------------------------

function outputDeploymentUrl(workspaceId) {
  const url = `https://${workspaceId}-3000.2.codesphere.com/`;
  console.log(`🔗 Deployment URL: ${url}`);

  // Write to GITHUB_OUTPUT
  const outputFile = process.env.GITHUB_OUTPUT;
  if (outputFile) {
    fs.appendFileSync(outputFile, `deployment-url=${url}\n`);
    fs.appendFileSync(outputFile, `workspace-id=${workspaceId}\n`);
  }

  // Write to GITHUB_STEP_SUMMARY
  const summaryFile = process.env.GITHUB_STEP_SUMMARY;
  if (summaryFile) {
    fs.appendFileSync(
      summaryFile,
      [
        "### 🚀 Codesphere Deployment",
        "",
        "| Property | Value |",
        "|----------|-------|",
        `| **URL** | [${url}](${url}) |`,
        `| **Workspace ID** | \`${workspaceId}\` |`,
        "",
      ].join("\n")
    );
  }
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const branch = resolveBranch();
  console.log(`🌿 Target branch: ${branch}`);

  // --- PR closed → delete workspace ---
  if (config.eventName === "pull_request" && config.prAction === "closed") {
    const ws = await findWorkspace();
    if (ws) {
      await deleteWorkspace(ws.id);
      console.log("✅ Workspace deleted.");
    } else {
      console.log("ℹ️  No workspace found — nothing to delete.");
    }
    return;
  }

  // --- PR opened/updated → create or update workspace ---
  const existing = await findWorkspace();

  if (existing) {
    const wsId = existing.id;
    await waitForRunning(wsId);
    await gitPull(wsId, branch);
    await setEnvVars(wsId, parseEnvVars(config.envVars));
    outputDeploymentUrl(wsId);
    await runPipeline(wsId, config.stages);
    console.log(`✅ Workspace ${wsId} updated.`);
  } else {
    const ws = await createWorkspace(branch);
    await waitForRunning(ws.id);
    outputDeploymentUrl(ws.id);
    await runPipeline(ws.id, config.stages);
    console.log("✅ New workspace created.");
  }
}

main().catch((err) => {
  console.error(`❌ ${err.message}`);
  process.exit(1);
});
