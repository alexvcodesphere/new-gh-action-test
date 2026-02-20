package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/codesphere-cloud/cs-go/api"
)

// ---------------------------------------------------------------------------
// Configuration (from action.yml inputs + GitHub context)
// ---------------------------------------------------------------------------

type config struct {
	apiUrl    *url.URL
	token     string
	teamId    int
	planId    int
	envVars   map[string]string
	vpnConfig string
	branch    string
	stages    []string

	repoUrl    string
	repository string
	eventName  string
	prAction   string
	prNumber   string
	headRef    string
	refName    string
}

func loadConfig() config {
	apiUrl, _ := url.Parse(env("INPUT_APIURL", "https://codesphere.com/api"))
	teamId, _ := strconv.Atoi(env("INPUT_TEAMID", "0"))
	planId, _ := strconv.Atoi(env("INPUT_PLANID", "8"))

	// Parse stages
	stagesStr := env("INPUT_STAGES", "prepare run")
	var stages []string
	for _, s := range strings.Fields(stagesStr) {
		if s != "" {
			stages = append(stages, s)
		}
	}

	// Parse env vars (KEY=VALUE per line)
	envVars := make(map[string]string)
	for _, line := range strings.Split(env("INPUT_ENV", ""), "\n") {
		line = strings.TrimSpace(line)
		if idx := strings.Index(line, "="); idx > 0 {
			envVars[line[:idx]] = line[idx+1:]
		}
	}

	// Load PR context from GitHub event payload
	prAction, prNumber := loadGitHubEvent()

	return config{
		apiUrl:    apiUrl,
		token:     os.Getenv("INPUT_TOKEN"),
		teamId:    teamId,
		planId:    planId,
		envVars:   envVars,
		vpnConfig: os.Getenv("INPUT_VPNCONFIG"),
		branch:    os.Getenv("INPUT_BRANCH"),
		stages:    stages,

		repoUrl:    fmt.Sprintf("%s/%s.git", os.Getenv("GITHUB_SERVER_URL"), os.Getenv("GITHUB_REPOSITORY")),
		repository: os.Getenv("GITHUB_REPOSITORY"),
		eventName:  os.Getenv("GITHUB_EVENT_NAME"),
		prAction:   prAction,
		prNumber:   prNumber,
		headRef:    os.Getenv("GITHUB_HEAD_REF"),
		refName:    env("GITHUB_REF_NAME", "main"),
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// loadGitHubEvent reads the PR action and number from GITHUB_EVENT_PATH.
func loadGitHubEvent() (action string, number string) {
	path := os.Getenv("GITHUB_EVENT_PATH")
	if path == "" {
		return "", ""
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", ""
	}
	var event struct {
		Action string `json:"action"`
		Number int    `json:"number"`
	}
	if json.Unmarshal(data, &event) == nil {
		return event.Action, strconv.Itoa(event.Number)
	}
	return "", ""
}

// ---------------------------------------------------------------------------
// Workspace naming — SINGLE SOURCE OF TRUTH
// Format: "<repo>-#<pr>" (e.g. "my-app-#42")
// ---------------------------------------------------------------------------

func (c *config) workspaceName() string {
	parts := strings.Split(c.repository, "/")
	repo := parts[len(parts)-1]
	return fmt.Sprintf("%s-#%s", repo, c.prNumber)
}

func (c *config) resolveBranch() string {
	if c.branch != "" {
		return c.branch
	}
	if c.headRef != "" {
		return c.headRef
	}
	return c.refName
}

// ---------------------------------------------------------------------------
// Workspace operations
// ---------------------------------------------------------------------------

func findWorkspace(client *api.Client, cfg *config) (*api.Workspace, error) {
	name := cfg.workspaceName()
	fmt.Printf("🔍 Looking for workspace '%s'...\n", name)

	workspaces, err := client.ListWorkspaces(cfg.teamId)
	if err != nil {
		return nil, fmt.Errorf("listing workspaces: %w", err)
	}

	for i := range workspaces {
		if workspaces[i].Name == name {
			fmt.Printf("  Found: id=%d\n", workspaces[i].Id)
			return &workspaces[i], nil
		}
	}
	return nil, nil
}

func createWorkspace(client *api.Client, cfg *config, branch string) (*api.Workspace, error) {
	name := cfg.workspaceName()
	fmt.Printf("🚀 Creating workspace '%s'...\n", name)

	ws, err := client.DeployWorkspace(api.DeployWorkspaceArgs{
		TeamId:        cfg.teamId,
		PlanId:        cfg.planId,
		Name:          name,
		EnvVars:       cfg.envVars,
		VpnConfigName: strPtr(cfg.vpnConfig),
		IsPrivateRepo: true,
		GitUrl:        strPtr(cfg.repoUrl),
		Branch:        strPtr(branch),
		Timeout:       5 * time.Minute,
	})
	if err != nil {
		return nil, fmt.Errorf("creating workspace: %w", err)
	}

	fmt.Printf("  Created: id=%d\n", ws.Id)
	return ws, nil
}

func deleteWorkspace(client *api.Client, wsId int) error {
	fmt.Printf("🗑️  Deleting workspace %d...\n", wsId)
	return client.DeleteWorkspace(wsId)
}

func updateWorkspace(client *api.Client, cfg *config, ws *api.Workspace, branch string) error {
	fmt.Println("  ⏰ Waiting for workspace to be running...")
	if err := client.WaitForWorkspaceRunning(ws, 5*time.Minute); err != nil {
		return err
	}
	fmt.Println("  ✅ Workspace is running.")

	fmt.Printf("  📥 Pulling branch '%s'...\n", branch)
	if err := client.GitPull(ws.Id, "origin", branch); err != nil {
		return fmt.Errorf("git pull: %w", err)
	}

	if len(cfg.envVars) > 0 {
		fmt.Printf("  🔧 Setting %d environment variable(s)...\n", len(cfg.envVars))
		if err := client.SetEnvVarOnWorkspace(ws.Id, cfg.envVars); err != nil {
			return fmt.Errorf("setting env vars: %w", err)
		}
	}

	return nil
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

func runPipeline(client *api.Client, wsId int, stages []string) error {
	if len(stages) == 0 {
		return nil
	}

	fmt.Printf("🔧 Running pipeline: %s\n", strings.Join(stages, " → "))

	for _, stage := range stages {
		fmt.Printf("  ▶ Starting '%s'...\n", stage)
		if err := client.StartPipelineStage(wsId, "", stage); err != nil {
			return fmt.Errorf("starting stage '%s': %w", stage, err)
		}

		// 'run' is fire-and-forget
		if stage == "run" {
			fmt.Printf("  ✅ '%s' triggered.\n", stage)
			continue
		}

		// Poll until done
		deadline := time.Now().Add(30 * time.Minute)
		for time.Now().Before(deadline) {
			time.Sleep(5 * time.Second)
			statuses, err := client.GetPipelineState(wsId, stage)
			if err != nil {
				continue // transient error, retry
			}

			allDone := true
			for _, s := range statuses {
				switch s.State {
				case "failure", "aborted":
					return fmt.Errorf("pipeline '%s' failed (state: %s)", stage, s.State)
				case "success":
					// good
				default:
					allDone = false
				}
			}

			if allDone && len(statuses) > 0 {
				fmt.Printf("  ✅ '%s' completed.\n", stage)
				break
			}
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// GitHub Actions output
// ---------------------------------------------------------------------------

func setOutputs(wsId int) {
	url := fmt.Sprintf("https://%d-3000.2.codesphere.com/", wsId)
	fmt.Printf("🔗 Deployment URL: %s\n", url)

	if f := os.Getenv("GITHUB_OUTPUT"); f != "" {
		appendToFile(f, fmt.Sprintf("deployment-url=%s\nworkspace-id=%d\n", url, wsId))
	}

	if f := os.Getenv("GITHUB_STEP_SUMMARY"); f != "" {
		appendToFile(f, fmt.Sprintf(
			"### 🚀 Codesphere Deployment\n\n| Property | Value |\n|----------|-------|\n| **URL** | [%s](%s) |\n| **Workspace** | `%d` |\n",
			url, url, wsId,
		))
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func strPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func appendToFile(path, content string) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	f.WriteString(content)
}

func fatal(msg string, err error) {
	fmt.Fprintf(os.Stderr, "❌ %s: %v\n", msg, err)
	os.Exit(1)
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	cfg := loadConfig()
	branch := cfg.resolveBranch()
	fmt.Printf("🌿 Target branch: %s\n", branch)

	client := api.NewClient(context.Background(), api.Configuration{
		BaseUrl: cfg.apiUrl,
		Token:   cfg.token,
	})

	// PR closed → delete workspace
	if cfg.eventName == "pull_request" && cfg.prAction == "closed" {
		ws, err := findWorkspace(client, &cfg)
		if err != nil {
			fatal("finding workspace", err)
		}
		if ws != nil {
			if err := deleteWorkspace(client, ws.Id); err != nil {
				fatal("deleting workspace", err)
			}
			fmt.Println("✅ Workspace deleted.")
		} else {
			fmt.Println("ℹ️  No workspace found — nothing to delete.")
		}
		return
	}

	// PR opened/updated → create or update
	existing, err := findWorkspace(client, &cfg)
	if err != nil {
		fatal("finding workspace", err)
	}

	if existing != nil {
		if err := updateWorkspace(client, &cfg, existing, branch); err != nil {
			fatal("updating workspace", err)
		}
		setOutputs(existing.Id)
		if err := runPipeline(client, existing.Id, cfg.stages); err != nil {
			fatal("running pipeline", err)
		}
		fmt.Printf("✅ Workspace %d updated.\n", existing.Id)
	} else {
		ws, err := createWorkspace(client, &cfg, branch)
		if err != nil {
			fatal("creating workspace", err)
		}
		setOutputs(ws.Id)
		if err := runPipeline(client, ws.Id, cfg.stages); err != nil {
			fatal("running pipeline", err)
		}
		fmt.Println("✅ New workspace created.")
	}
}
