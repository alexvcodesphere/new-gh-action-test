#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Codesphere Deploy Action — Entrypoint
#
# This script orchestrates workspace lifecycle management using the Codesphere
# CLI (cs-go). It handles:
#   1. Installing the CLI from GitHub releases
#   2. Creating or updating a workspace for the current repo/branch
#   3. Deleting workspaces when a PR is closed
#   4. Outputting the workspace URL for GitHub Deployments
#
# All inputs are passed via environment variables set by the composite action.
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration (set by action.yml)
# ---------------------------------------------------------------------------
CS_API_URL="${INPUT_APIURL:-https://codesphere.com/api}"
CS_TOKEN="${INPUT_TOKEN}"
CS_TEAM_ID="${INPUT_TEAMID}"
PLAN_ID="${INPUT_PLANID:-8}"
ENV_VARS="${INPUT_ENV:-}"
VPN_CONFIG="${INPUT_VPNCONFIG:-}"
BRANCH="${INPUT_BRANCH:-}"

# GitHub context
REPO_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git"
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
PR_ACTION="${PR_ACTION:-}"

# ---------------------------------------------------------------------------
# Step 1: Install the Codesphere CLI
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
    echo "❌ Failed to find CLI download URL"
    exit 1
  fi

  wget -qO "$install_dir/cs" "$download_url"
  chmod +x "$install_dir/cs"
  export PATH="$install_dir:$PATH"

  echo "✅ CLI installed: $(cs version 2>/dev/null || echo 'unknown version')"
}

# ---------------------------------------------------------------------------
# Step 2: Resolve the target branch
# ---------------------------------------------------------------------------
resolve_branch() {
  if [ -n "$BRANCH" ]; then
    echo "$BRANCH"
    return
  fi

  # For PRs, use the head branch; for pushes, use the ref name
  if [ -n "${GITHUB_HEAD_REF:-}" ]; then
    echo "$GITHUB_HEAD_REF"
  else
    echo "${GITHUB_REF_NAME:-main}"
  fi
}

# ---------------------------------------------------------------------------
# Step 3: Find existing workspace for this repo + branch
#
# Returns two values via stdout (space-separated): WORKSPACE_ID DEV_DOMAIN
# Example: "74941 74941-3000.2.codesphere.com"
# Returns empty string if no matching workspace is found.
# ---------------------------------------------------------------------------
find_workspace() {
  local target_branch="$1"
  local workspace_name="${GITHUB_REPOSITORY##*/}-${target_branch}"

  echo "🔍 Searching for workspace matching name '${workspace_name}'..." >&2

  # List workspaces and find one matching our repository
  local workspaces
  workspaces=$(cs list workspaces -t "$CS_TEAM_ID" -a "$CS_API_URL" 2>/dev/null || echo "")

  if [ -z "$workspaces" ]; then
    echo ""
    return
  fi

  # Debug: show raw output so we can verify parsing
  echo "  Raw workspace list:" >&2
  echo "$workspaces" | head -10 >&2

  # TODO(dev): This table parsing is FRAGILE — it depends on the exact column
  # order of `cs list workspaces`. If the CLI ever adds a `--output json` or
  # `-o json` flag, replace this entire block with:
  #   cs list workspaces -t "$CS_TEAM_ID" -a "$CS_API_URL" -o json | jq '...'
  #
  # Current table format (as of cs-go v0.x):
  #   | TEAM ID | ID   | NAME       | REPOSITORY                    | DEV DOMAIN                |
  #   | 123     | 4567 | my-ws      | https://github.com/org/repo   | 4567-3000.2.codesphere.com|
  #
  # We match on the workspace NAME (column $4) which follows our naming
  # convention: "<repo-name>-<branch>". This ensures each branch/PR gets
  # its own workspace instead of reusing one from a different branch.
  local match
  match=$(echo "$workspaces" | grep -i "$workspace_name" | head -1 || echo "")

  # Fallback: if no name match, try matching by repo URL
  if [ -z "$match" ]; then
    echo "  No workspace matched by name, trying repo URL match..." >&2
    match=$(echo "$workspaces" | grep -i "$GITHUB_REPOSITORY" | head -1 || echo "")
  fi

  if [ -z "$match" ]; then
    echo ""
    return
  fi

  echo "  Matched row: $match" >&2

  # TODO(dev): fragile — column indices assume this order:
  #   $2=TEAM ID, $3=ID, $4=NAME, $5=REPOSITORY, $6=DEV DOMAIN
  # If the CLI changes column order, this will break silently.
  local ws_id dev_domain
  ws_id=$(echo "$match" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}')
  dev_domain=$(echo "$match" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $6); print $6}')

  # Validate workspace ID is a number
  if [[ "$ws_id" =~ ^[0-9]+$ ]]; then
    echo "${ws_id} ${dev_domain}"
  else
    echo "  ⚠️  Could not parse workspace ID from: $match" >&2
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Step 4: Create a new workspace
# ---------------------------------------------------------------------------
create_workspace() {
  local target_branch="$1"
  local workspace_name="${GITHUB_REPOSITORY##*/}-${target_branch}"

  echo "🚀 Creating workspace '${workspace_name}'..."

  local cmd=(cs create workspace "$workspace_name"
    -a "$CS_API_URL"
    -t "$CS_TEAM_ID"
    -p "$PLAN_ID"
    -r "$REPO_URL"
    -b "$target_branch"
    -P
  )

  # Add environment variables
  if [ -n "$ENV_VARS" ]; then
    while IFS= read -r line; do
      line=$(echo "$line" | xargs)  # trim whitespace
      if [ -n "$line" ] && [[ "$line" == *"="* ]]; then
        cmd+=(-e "$line")
      fi
    done <<< "$ENV_VARS"
  fi

  # Add VPN config if specified
  if [ -n "$VPN_CONFIG" ]; then
    cmd+=(--vpn "$VPN_CONFIG")
  fi

  echo "  Command: ${cmd[*]}"
  "${cmd[@]}"

  # After creation, look up the workspace to get its dev domain
  local result
  result=$(find_workspace "$target_branch")
  if [ -n "$result" ]; then
    local ws_id dev_domain
    ws_id=$(echo "$result" | awk '{print $1}')
    dev_domain=$(echo "$result" | awk '{print $2}')
    set_deployment_url "$dev_domain" "$ws_id"
  fi
}

# ---------------------------------------------------------------------------
# Step 5: Update an existing workspace (pull latest code)
# ---------------------------------------------------------------------------
update_workspace() {
  local workspace_id="$1"
  local target_branch="$2"
  local dev_domain="${3:-}"

  echo "🔄 Updating workspace ${workspace_id}..."

  # Ensure workspace is running before pulling
  echo "  ⏰ Waking up workspace..."
  cs wake-up \
    -a "$CS_API_URL" \
    -w "$workspace_id" \
    --timeout 5m || echo "  (workspace may already be running)"

  echo "  📥 Pulling branch '${target_branch}'..."
  cs git pull \
    -a "$CS_API_URL" \
    -w "$workspace_id" \
    --branch "$target_branch"

  # Update environment variables if specified
  if [ -n "$ENV_VARS" ]; then
    echo "🔧 Setting environment variables..."

    local cmd=(cs set-env -a "$CS_API_URL" -w "$workspace_id")

    while IFS= read -r line; do
      line=$(echo "$line" | xargs)  # trim whitespace
      if [ -n "$line" ] && [[ "$line" == *"="* ]]; then
        cmd+=(--env-var "$line")
      fi
    done <<< "$ENV_VARS"

    "${cmd[@]}"
  fi

  # Output deployment URL
  if [ -n "$dev_domain" ]; then
    set_deployment_url "$dev_domain" "$workspace_id"
  fi
}

# ---------------------------------------------------------------------------
# Step 6: Delete workspace (on PR close)
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
# Step 7: Set deployment URL as GitHub output and summary
# ---------------------------------------------------------------------------
set_deployment_url() {
  local dev_domain="$1"
  local workspace_id="$2"

  if [ -z "$dev_domain" ]; then
    return
  fi

  local url="https://${dev_domain}"

  echo "🔗 Deployment URL: ${url}"

  # Set as GitHub Action output
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "deployment-url=${url}" >> "$GITHUB_OUTPUT"
    echo "workspace-id=${workspace_id}" >> "$GITHUB_OUTPUT"
  fi

  # Add to GitHub Step Summary
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### 🚀 Codesphere Deployment"
      echo ""
      echo "| Property | Value |"
      echo "|----------|-------|"
      echo "| **URL** | [${url}](${url}) |"
      echo "| **Workspace ID** | ${workspace_id} |"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

# =============================================================================
# Main
# =============================================================================
main() {
  install_cli

  local target_branch
  target_branch=$(resolve_branch)
  echo "🌿 Target branch: ${target_branch}"

  # Handle PR close → delete workspace
  if [ "$EVENT_NAME" = "pull_request" ] && [ "$PR_ACTION" = "closed" ]; then
    local result
    result=$(find_workspace "$target_branch")

    if [ -n "$result" ]; then
      local ws_id
      ws_id=$(echo "$result" | awk '{print $1}')
      delete_workspace "$ws_id"
      echo "✅ Workspace deleted."
    else
      echo "⚠️  No workspace found to delete."
    fi
    exit 0
  fi

  # Create or update workspace
  local result
  result=$(find_workspace "$target_branch")

  if [ -n "$result" ]; then
    local ws_id dev_domain
    ws_id=$(echo "$result" | awk '{print $1}')
    dev_domain=$(echo "$result" | awk '{print $2}')
    update_workspace "$ws_id" "$target_branch" "$dev_domain"
    echo "✅ Workspace ${ws_id} updated."
  else
    create_workspace "$target_branch"
    echo "✅ Workspace created."
  fi
}

main "$@"
