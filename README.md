# Codesphere Deployment Action

This action creates a preview environment of your repository in [Codesphere](https://codesphere.com) using the official [Codesphere CLI (`cs-go`)](https://github.com/codesphere-cloud/cs-go).

## How it works

1. **Installs** the Codesphere CLI from [GitHub releases](https://github.com/codesphere-cloud/cs-go/releases)
2. **Creates** a new workspace for your repo — or **updates** an existing one via `git pull`
3. **Deletes** the workspace when a PR is closed

All logic lives in [`entrypoint.sh`](entrypoint.sh) — a readable shell script you can audit yourself.

## :warning: Prerequisites

- A Codesphere account with an **API token** (generate one from your account settings)
- Your GitHub repository connected to your Codesphere account

## Inputs

### `token`

**Required.** Codesphere API token. Store as a [GitHub secret](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions).

### `teamId`

**Required.** Numeric ID of your Codesphere team. Find it in the Codesphere UI or by running `cs list teams`.

### `planId`

Numeric plan ID for the workspace. Default: `8`.

Discover available plans with `cs list plans`.

### `apiUrl`

Base URL of the Codesphere instance. Default: `https://codesphere.com`.

### `env`

Environment variables to set in the workspace. One per line, in `KEY=VALUE` format. Works with GitHub secrets:

```yaml
env: |
  MY_VAR=hello
  MY_SECRET=${{ secrets.MY_SECRET }}
```

### `vpnConfig`

Name of the VPN config to connect the workspace to. Must be configured in the team first.

### `branch`

Git branch to deploy. Auto-detected from the PR head branch or push ref if not specified.

## Example usage

### Action

```yaml
# .github/workflows/codesphere.yaml
uses: codesphere-cloud/gh-action-deploy@main
with:
  token: ${{ secrets.CS_TOKEN }}
  teamId: "12345"
  planId: "8"
  env: |
    MY_ENV=test
```

### Workflow

```yaml
# .github/workflows/codesphere.yaml
on:
  workflow_dispatch:
  pull_request:
    types:
      - closed # → deletes the workspace
      - opened # → creates a workspace
      - reopened # → creates a workspace
      - synchronize # → updates the workspace

permissions:
  contents: read
  pull-requests: read
  deployments: write

jobs:
  deploy:
    concurrency: codesphere
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Deploy
        uses: codesphere-cloud/gh-action-deploy@main
        with:
          token: ${{ secrets.CS_TOKEN }}
          teamId: ${{ secrets.CS_TEAM_ID }}
          planId: "8"
          env: |
            MY_ENV=test
            MY_SECRET=${{ secrets.MY_SECRET }}
```

## Migration from v1 (email/password)

If you're upgrading from the previous version that used email/password authentication:

| Old input                  | New input         | Change                                                    |
| -------------------------- | ----------------- | --------------------------------------------------------- |
| `email` + `password`       | `token`           | Generate an API token in your Codesphere account settings |
| `team` (name)              | `teamId` (number) | Use `cs list teams` to find your team ID                  |
| `plan` (name like "Boost") | `planId` (number) | Use `cs list plans` to find plan IDs                      |
| `onDemand`                 | —                 | Removed                                                   |
| `restricted`               | —                 | Removed (use `--public-dev-domain` via CLI directly)      |
| `cloneDepth`               | —                 | Removed                                                   |

## Use with private submodules

The workflows above use the GitHub action access token to clone and update the repository (See `GITHUB_TOKEN: ${{secrets.GITHUB_TOKEN}}`).
`${{secrets.GITHUB_TOKEN}}` is scoped to the current repository, so if you have private submodules you will need to provide your own [PAT](https://help.github.com/en/github/authenticating-to-github/creating-a-personal-access-token-for-the-command-line).

1. Create your own [private access token](https://help.github.com/en/github/authenticating-to-github/creating-a-personal-access-token-for-the-command-line).
2. Create a secret called `PAT`.
3. Update your workflow to use that token by replacing `GITHUB_TOKEN: ${{secrets.GITHUB_TOKEN}}` with `GITHUB_TOKEN: ${{secrets.PAT}}`
