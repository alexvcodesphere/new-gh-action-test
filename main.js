// =============================================================================
// Codesphere Deploy Action
// https://github.com/codesphere-cloud/gh-action-deploy
//
// Manages workspace lifecycle via the Codesphere REST API.
// Zero external dependencies — uses only Node.js built-in modules.
//
// API docs: https://codesphere.com/api/scalar-ui/
// =============================================================================

const https = require("https");
const fs = require("fs");

// ---------------------------------------------------------------------------
// GitHub event payload (PR number, action, etc.)
// ---------------------------------------------------------------------------
let ghEvent = {};
try {
  if (process.env.GITHUB_EVENT_PATH) {
    ghEvent = JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"));
  }
} catch {
  // Not in GitHub Actions
}

// ---------------------------------------------------------------------------
// Configuration (from action.yml inputs + GitHub context)
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

  repoUrl: `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}.git`,
  repository: process.env.GITHUB_REPOSITORY || "",
  eventName: process.env.GITHUB_EVENT_NAME || "",
  prAction: ghEvent.action || "",
  prNumber: String(ghEvent.number || ""),
  headRef: process.env.GITHUB_HEAD_REF || "",
  refName: process.env.GITHUB_REF_NAME || "main",
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Workspace name — SINGLE SOURCE OF TRUTH
// Format: "<repo>-#<pr>" (e.g. "my-app-#42")
function workspaceName() {
  return `${config.repository.split("/").pop()}-#${config.prNumber}`;
}

function resolveBranch() {
  return config.branch || config.headRef || config.refName;
}

function parseEnvVars(input) {
  if (!input.trim()) return [];
  return input
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && l.includes("="))
    .map((l) => {
      const i = l.indexOf("=");
      return { name: l.slice(0, i), value: l.slice(i + 1) };
    });
}

// ---------------------------------------------------------------------------
// HTTP client — Codesphere API
// ---------------------------------------------------------------------------
function api(method, path, body = null) {
  return new Promise((resolve, reject) => {
    const base = config.apiUrl.replace(/\/+$/, "");
    const url = new URL(`${base}${path.startsWith("/") ? path : `/${path}`}`);

    const req = https.request(
      {
        method,
        hostname: url.hostname,
        port: url.port,
        path: url.pathname + url.search,
        headers: {
          Authorization: `Bearer ${config.token}`,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
      },
      (res) => {
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
            // Truncate HTML error pages to keep logs readable
            const detail = data.length > 200 ? data.slice(0, 200) + "..." : data;
            reject(new Error(`${method} ${path} → ${res.statusCode}: ${detail}`));
          }
        });
      }
    );

    req.on("error", reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Workspace operations
// ---------------------------------------------------------------------------
async function findWorkspace() {
  const name = workspaceName();
  console.log(`🔍 Looking for workspace '${name}'...`);

  const workspaces = await api("GET", `/workspaces/team/${config.teamId}`);
  const ws = workspaces.find((w) => w.name === name);

  if (ws) console.log(`  Found: id=${ws.id}`);
  return ws || null;
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

  const env = parseEnvVars(config.envVars);
  if (env.length) body.env = env;
  if (config.vpnConfig) body.vpnConfig = config.vpnConfig;

  const ws = await api("POST", "/workspaces", body);
  console.log(`  Created: id=${ws.id}`);
  return ws;
}

async function deleteWorkspace(id) {
  console.log(`🗑️  Deleting workspace ${id}...`);
  await api("DELETE", `/workspaces/${id}`);
}

async function waitForRunning(id, timeoutMs = 300_000) {
  console.log("  ⏰ Waiting for workspace to be running...");
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const { isRunning } = await api("GET", `/workspaces/${id}/status`);
    if (isRunning) {
      console.log("  ✅ Workspace is running.");
      return;
    }
    await sleep(5000);
  }

  throw new Error(`Workspace ${id} did not start within ${timeoutMs / 1000}s`);
}

async function gitPull(id, branch) {
  console.log(`  📥 Pulling branch '${branch}'...`);
  await api("POST", `/workspaces/${id}/git/pull/origin/${branch}`);
}

async function setEnvVars(id, vars) {
  if (!vars.length) return;
  console.log(`  🔧 Setting ${vars.length} environment variable(s)...`);
  await api("PUT", `/workspaces/${id}/env-vars`, vars);
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------
async function runPipeline(id, stages) {
  if (!stages.length) return;
  console.log(`🔧 Running pipeline: ${stages.join(" → ")}`);

  for (const stage of stages) {
    console.log(`  ▶ Starting '${stage}'...`);
    await api("POST", `/workspaces/${id}/pipeline/${stage}/start`);

    // 'run' is fire-and-forget
    if (stage === "run") {
      console.log(`  ✅ '${stage}' triggered.`);
      continue;
    }

    // Poll until done (status returns array of replicas, each with .state)
    const deadline = Date.now() + 1_800_000; // 30 min
    while (Date.now() < deadline) {
      await sleep(5000);
      const replicas = await api("GET", `/workspaces/${id}/pipeline/${stage}`);
      const states = (Array.isArray(replicas) ? replicas : [replicas]).map((r) => r.state);

      if (states.every((s) => s === "success")) {
        console.log(`  ✅ '${stage}' completed.`);
        break;
      }
      if (states.some((s) => s === "failure" || s === "aborted")) {
        throw new Error(`Pipeline '${stage}' failed (${states.join(", ")})`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// GitHub Actions outputs
// ---------------------------------------------------------------------------
function setOutputs(workspaceId) {
  const url = `https://${workspaceId}-3000.2.codesphere.com/`;
  console.log(`🔗 Deployment URL: ${url}`);

  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `deployment-url=${url}\nworkspace-id=${workspaceId}\n`);
  }

  if (process.env.GITHUB_STEP_SUMMARY) {
    fs.appendFileSync(
      process.env.GITHUB_STEP_SUMMARY,
      `### 🚀 Codesphere Deployment\n\n| Property | Value |\n|----------|-------|\n| **URL** | [${url}](${url}) |\n| **Workspace** | \`${workspaceId}\` |\n`
    );
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const branch = resolveBranch();
  console.log(`🌿 Target branch: ${branch}`);

  // PR closed → clean up
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

  // PR opened/updated → create or update
  const existing = await findWorkspace();

  if (existing) {
    await waitForRunning(existing.id);
    await gitPull(existing.id, branch);
    await setEnvVars(existing.id, parseEnvVars(config.envVars));
    setOutputs(existing.id);
    await runPipeline(existing.id, config.stages);
    console.log(`✅ Workspace ${existing.id} updated.`);
  } else {
    const ws = await createWorkspace(branch);
    await waitForRunning(ws.id);
    setOutputs(ws.id);
    await runPipeline(ws.id, config.stages);
    console.log("✅ New workspace created.");
  }
}

main().catch((err) => {
  console.error(`❌ ${err.message}`);
  process.exit(1);
});
