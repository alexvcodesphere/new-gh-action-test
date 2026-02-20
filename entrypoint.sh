#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Codesphere Deploy Action — Entrypoint
# https://github.com/codesphere-cloud/gh-action-deploy
#
# This script orchestrates workspace lifecycle management using the Codesphere
# CLI (cs-go): https://github.com/codesphere-cloud/cs-go
#
# What it does:
#   1. Downloads and installs the Codesphere CLI
#   2. Determines which branch to deploy (from PR or push context)
#   3. Finds an existing workspace by name, or creates a new one
#   4. For existing workspaces: wakes up → pulls latest code → sets env vars
#   5. Outputs the workspace URL for GitHub Deployments integration
#   6. On PR close: deletes the workspace
#
# All inputs are passed as environment variables by the composite action
# defined in action.yml.
#
# =============================================================================
# KNOWN LIMITATIONS / TODO for developers:
#
# 1. WORKSPACE LOOKUP parses the CLI's pipe-separated table output using awk.
#    This is FRAGILE and depends on the exact column order. When the CLI adds
#    `--output json` support, replace the table parsing in find_workspace()
#    with: cs list workspaces ... -o json | jq '.[] | select(.name == "...")'
#    See: https://github.com/codesphere-cloud/cs-go/issues
#
# 2. CLI INSTALLATION downloads the latest release on every run (~15MB).
#    Consider pinning to a specific version for reproducibility, or caching
#    the binary across workflow runs.
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration (set by action.yml inputs)
# ---------------------------------------------------------------------------
CS_API_URL="${INPUT_APIURL:-https://codesphere.com/api}"
CS_TOKEN="${INPUT_TOKEN}"
CS_TEAM_ID="${INPUT_TEAMID}"
PLAN_ID="${INPUT_PLANID:-8}"
ENV_VARS="${INPUT_ENV:-}"
VPN_CONFIG="${INPUT_VPNCONFIG:-}"
BRANCH="${INPUT_BRANCH:-}"
STAGES="${INPUT_STAGES:-prepare test run}"

# GitHub context (automatically set by GitHub Actions runner)
REPO_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git"
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
PR_ACTION="${PR_ACTION:-}"
PR_NUMBER="${PR_NUMBER:-}"

# ---------------------------------------------------------------------------
# Workspace naming convention — SINGLE SOURCE OF TRUTH
#
# Change this function to alter how workspaces are named. The name is used
# both when creating new workspaces and when looking up existing ones.
# Format: "<repo-name>-#<pr-number>"  (e.g. "my-app-#42")
# ---------------------------------------------------------------------------
workspace_name() {
  echo "${GITHUB_REPOSITORY##*/}-#${PR_NUMBER}"
}

# ---------------------------------------------------------------------------
# Install the Codesphere CLI binary from GitHub releases
# ---------------------------------------------------------------------------
install_cli() {
  echo "📦 Installing Codesphere CLI..."

  local install_dir="$HOME/.local/bin"
  mkdir -p "$install_dir"

  local download_url
  download_url=$(wget -qO- 'https://api.github.com/repos/codesphere-cloud/cs-go/releases/latest' \
    | grep browser_download_url \
    | grep linux_amd64 \
    | head -1 \
    | sed 's/.*"browser_download_url": *"//' \
    | sed 's/".*//')

  if [ -z "$download_url" ]; then
    echo "❌ Failed to resolve CLI download URL from GitHub releases"
    exit 1
  fi

  wget -qO "$install_dir/cs" "$download_url"
  chmod +x "$install_dir/cs"
  export PATH="$install_dir:$PATH"

  echo "✅ CLI installed: $(cs version 2>/dev/null || echo 'unknown version')"
}

# ---------------------------------------------------------------------------
# Determine the target branch from the GitHub Actions event context
# ---------------------------------------------------------------------------
resolve_branch() {
  if [ -n "$BRANCH" ]; then
    echo "$BRANCH"
    return
  fi

  # For PRs, use the head (source) branch; for pushes, use the ref name
  if [ -n "${GITHUB_HEAD_REF:-}" ]; then
    echo "$GITHUB_HEAD_REF"
  else
    echo "${GITHUB_REF_NAME:-main}"
  fi
}

# ---------------------------------------------------------------------------
# Find an existing workspace by name
#
# Looks for a workspace whose NAME matches our naming convention.
# Returns: "WORKSPACE_ID DEV_DOMAIN" (space-separated) or empty string.
#
# ⚠️  FRAGILE: Parses pipe-separated table output from `cs list workspaces`.
#     Replace with JSON parsing when the CLI supports `--output json`.
#     See the KNOWN LIMITATIONS section at the top of this file.
# ---------------------------------------------------------------------------
find_workspace() {
  local target_branch="$1"
  local ws_name
  ws_name=$(workspace_name "$target_branch")

  echo "🔍 Looking for workspace '${ws_name}'..." >&2

  local workspaces
  workspaces=$(cs list workspaces -t "$CS_TEAM_ID" -a "$CS_API_URL" 2>/dev/null || echo "")

  if [ -z "$workspaces" ]; then
    echo "" # No workspaces found
    return
  fi

  # Match by workspace name (exact naming convention match)
  local match
  match=$(echo "$workspaces" | grep -i "$ws_name" | head -1 || echo "")

  if [ -z "$match" ]; then
    echo "" # No workspace with this name
    return
  fi

  echo "  Found: $match" >&2

  # Extract workspace ID and dev domain from the matched table row.
  # Expected column order: | TEAM ID | ID | NAME | REPOSITORY | DEV DOMAIN |
  # Field indices after splitting by '|': $2=TEAM_ID $3=ID $4=NAME $5=REPO $6=DEV_DOMAIN
  local ws_id dev_domain
  ws_id=$(echo "$match" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}')
  dev_domain=$(echo "$match" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $6); print $6}')

  # Validate that the extracted ID is actually numeric
  if [[ "$ws_id" =~ ^[0-9]+$ ]]; then
    echo "${ws_id} ${dev_domain}"
  else
    echo "❌ Failed to parse workspace ID from table row: $match" >&2
    echo "   Expected a numeric ID in column 3, got: '${ws_id}'" >&2
    echo "   The CLI table format may have changed. See KNOWN LIMITATIONS in entrypoint.sh." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Create a new workspace for the given branch
# ---------------------------------------------------------------------------
create_workspace() {
  local target_branch="$1"
  local ws_name
  ws_name=$(workspace_name "$target_branch")

  echo "🚀 Creating workspace '${ws_name}'..."

  # Build the command with required flags
  local cmd=(cs create workspace "$ws_name"
    -a "$CS_API_URL"
    -t "$CS_TEAM_ID"
    -p "$PLAN_ID"
    -r "$REPO_URL"
    -b "$target_branch"
    -P  # Private repository (safe default — works for both public and private repos)
  )

  # Append optional environment variables
  if [ -n "$ENV_VARS" ]; then
    while IFS= read -r line; do
      line=$(echo "$line" | xargs)  # trim whitespace
      if [ -n "$line" ] && [[ "$line" == *"="* ]]; then
        cmd+=(-e "$line")
      fi
    done <<< "$ENV_VARS"
  fi

  # Append optional VPN config
  if [ -n "$VPN_CONFIG" ]; then
    cmd+=(--vpn "$VPN_CONFIG")
  fi

  echo "  Running: ${cmd[*]}"
  "${cmd[@]}"

  # Look up the newly created workspace to get its dev domain for the deployment URL
  local result
  result=$(find_workspace "$target_branch")
  if [ -n "$result" ]; then
    local ws_id dev_domain
    ws_id=$(echo "$result" | awk '{print $1}')
    dev_domain=$(echo "$result" | awk '{print $2}')
    output_deployment_url "$dev_domain" "$ws_id"
  fi
}

# ---------------------------------------------------------------------------
# Update an existing workspace: wake up → pull code → set env vars
# ---------------------------------------------------------------------------
update_workspace() {
  local workspace_id="$1"
  local target_branch="$2"
  local dev_domain="${3:-}"

  echo "🔄 Updating workspace ${workspace_id}..."

  # Wake up the workspace if it's stopped (e.g. on-demand workspaces)
  echo "  ⏰ Waking up workspace..."
  cs wake-up \
    -a "$CS_API_URL" \
    -w "$workspace_id" \
    --timeout 5m || echo "  (workspace may already be running)"

  # Pull the latest code from the target branch
  echo "  📥 Pulling branch '${target_branch}'..."
  cs git pull \
    -a "$CS_API_URL" \
    -w "$workspace_id" \
    --branch "$target_branch"

  # Set environment variables if provided
  if [ -n "$ENV_VARS" ]; then
    echo "  🔧 Setting environment variables..."

    local cmd=(cs set-env -a "$CS_API_URL" -w "$workspace_id")

    while IFS= read -r line; do
      line=$(echo "$line" | xargs)  # trim whitespace
      if [ -n "$line" ] && [[ "$line" == *"="* ]]; then
        cmd+=(--env-var "$line")
      fi
    done <<< "$ENV_VARS"

    "${cmd[@]}"
  fi

  # Output the deployment URL for GitHub Deployments integration
  if [ -n "$dev_domain" ]; then
    output_deployment_url "$dev_domain" "$workspace_id"
  fi
}

# ---------------------------------------------------------------------------
# Delete a workspace (called on PR close)
# ---------------------------------------------------------------------------
delete_workspace() {
  local workspace_id="$1"

  echo "🗑️  Deleting workspace ${workspace_id}..."

  cs delete workspace \
    -a "$CS_API_URL" \
    -w "$workspace_id" \
    --yes
}

# ---------------------------------------------------------------------------
# Write deployment URL to GitHub Actions output and step summary
#
# This enables:
#   - The "View deployment" button on PRs (via chrnorm/deployment-status)
#   - Accessing the URL in downstream steps via ${{ steps.deploy.outputs.deployment-url }}
# ---------------------------------------------------------------------------
output_deployment_url() {
  local dev_domain="$1"
  local workspace_id="$2"

  if [ -z "$dev_domain" ]; then
    return
  fi

  local url="https://${dev_domain}"
  echo "🔗 Deployment URL: ${url}"

  # Write to GitHub Actions outputs (accessible by subsequent steps)
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "deployment-url=${url}" >> "$GITHUB_OUTPUT"
    echo "workspace-id=${workspace_id}" >> "$GITHUB_OUTPUT"
  fi

  # Write a summary table (visible in the Actions run page)
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### 🚀 Codesphere Deployment"
      echo ""
      echo "| Property | Value |"
      echo "|----------|-------|"
      echo "| **URL** | [${url}](${url}) |"
      echo "| **Workspace ID** | \`${workspace_id}\` |"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

# ---------------------------------------------------------------------------
# Run pipeline stages (prepare, test, run)
# ---------------------------------------------------------------------------
run_pipeline() {
  local workspace_id="$1"

  if [ -z "$STAGES" ]; then
    echo "  ⏭️  No pipeline stages to run."
    return
  fi

  echo "🔧 Running pipeline stages: ${STAGES}..."

  # shellcheck disable=SC2086
  cs start pipeline \
    -a "$CS_API_URL" \
    -w "$workspace_id" \
    $STAGES
}

# =============================================================================
# Main — orchestrate the deployment lifecycle
# =============================================================================
main() {
  install_cli

  local target_branch
  target_branch=$(resolve_branch)
  echo "🌿 Target branch: ${target_branch}"

  # --- PR closed → clean up workspace ---
  if [ "$EVENT_NAME" = "pull_request" ] && [ "$PR_ACTION" = "closed" ]; then
    local result
    result=$(find_workspace "$target_branch")

    if [ -n "$result" ]; then
      local ws_id
      ws_id=$(echo "$result" | awk '{print $1}')
      delete_workspace "$ws_id"
      echo "✅ Workspace deleted."
    else
      echo "ℹ️  No workspace found for branch '${target_branch}' — nothing to delete."
    fi
    exit 0
  fi

  # --- PR opened/updated or push → create or update workspace ---
  local result
  result=$(find_workspace "$target_branch")

  if [ -n "$result" ]; then
    local ws_id dev_domain
    ws_id=$(echo "$result" | awk '{print $1}')
    dev_domain=$(echo "$result" | awk '{print $2}')
    update_workspace "$ws_id" "$target_branch" "$dev_domain"
    run_pipeline "$ws_id"
    echo "✅ Workspace ${ws_id} updated."
  else
    create_workspace "$target_branch"
    # Look up the workspace we just created to get its ID for the pipeline
    result=$(find_workspace "$target_branch")
    if [ -n "$result" ]; then
      local ws_id_new
      ws_id_new=$(echo "$result" | awk '{print $1}')
      run_pipeline "$ws_id_new"
    fi
    echo "✅ New workspace created."
  fi
}

main "$@"
