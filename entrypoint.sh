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
#
# All inputs are passed via environment variables set by the composite action.
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration (set by action.yml)
# ---------------------------------------------------------------------------
CS_API_URL="${INPUT_APIURL:-https://codesphere.com}"
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
# Step 3: Find existing workspace for this repo
# ---------------------------------------------------------------------------
find_workspace() {
  local target_branch="$1"

  echo "🔍 Searching for existing workspace..." >&2

  # List workspaces as JSON and find one matching our repo URL
  local workspaces
  workspaces=$(cs list workspaces -t "$CS_TEAM_ID" -a "$CS_API_URL" 2>/dev/null || echo "")

  if [ -z "$workspaces" ]; then
    echo ""
    return
  fi

  # Parse workspace ID from output — the CLI outputs a table, so we grep
  # for lines containing our repo URL. This is a best-effort match.
  # The exact output format may vary; adjust parsing if needed.
  echo "$workspaces" | grep -i "$GITHUB_REPOSITORY" | head -1 | awk '{print $1}' || echo ""
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
}

# ---------------------------------------------------------------------------
# Step 5: Update an existing workspace (pull latest code)
# ---------------------------------------------------------------------------
update_workspace() {
  local workspace_id="$1"
  local target_branch="$2"

  echo "🔄 Updating workspace ${workspace_id} (pulling branch '${target_branch}')..."

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
    local ws_id
    ws_id=$(find_workspace "$target_branch")

    if [ -n "$ws_id" ]; then
      delete_workspace "$ws_id"
      echo "✅ Workspace deleted."
    else
      echo "⚠️  No workspace found to delete."
    fi
    exit 0
  fi

  # Create or update workspace
  local ws_id
  ws_id=$(find_workspace "$target_branch")

  if [ -n "$ws_id" ]; then
    update_workspace "$ws_id" "$target_branch"
    echo "✅ Workspace ${ws_id} updated."
  else
    create_workspace "$target_branch"
    echo "✅ Workspace created."
  fi
}

main "$@"
