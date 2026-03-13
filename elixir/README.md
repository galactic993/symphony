# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work (or reacts to Linear webhooks)
2. Creates an isolated workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". The default `WORKFLOW.md`
     now checks the ticket's team workflow at run start and creates those missing custom
     states through Linear GraphQL when the configured token has permission to edit team
     workflow settings. If your token cannot create workflow states, add them manually in
     Team Settings → Workflow in Linear before running Symphony. For existing teams, you can
     retrofit the required states with `bash elixir/ensure-workflow-states.sh MEZ`.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

`mise exec -- make all` is the full CI-quality gate (`build`, `fmt-check`, `lint`,
`coverage`, `dialyzer`). Use the run commands above for local startup; use `make all`
when you want the full validation pass.

### Run with `dotenvx` + Keychain + cloudflared

Store `LINEAR_API_KEY` in macOS Keychain once, then start Symphony through `dotenvx`:

```bash
cd symphony/elixir
make linear-key
make run-symphony
```

`./scripts/run-symphony.sh` does the following in one command:

1. Starts `cloudflared tunnel run <name>` when needed (default tunnel name: `symphony-webhook`)
2. Waits until the tunnel is ready
3. Loads `LINEAR_API_KEY` (prefers exported env, falls back to macOS Keychain)
4. Launches Symphony via `dotenvx run -- mise exec -- ./bin/symphony ./WORKFLOW.md`

Useful environment variables:

- `SYMPHONY_CLOUDFLARED_ENABLED` (`1` by default, set `0` to skip tunnel startup)
- `SYMPHONY_CLOUDFLARED_TUNNEL` (`symphony-webhook` by default)
- `SYMPHONY_CLOUDFLARED_LOG` (`/tmp/symphony-cloudflared.log` by default)
- `SYMPHONY_CLOUDFLARED_WAIT_SECONDS` (`20` by default)

For tmux-based boot/startup flows, use:

```bash
cd symphony/elixir
make run-symphony-tmux
```

or call `./scripts/run-symphony-tmux.sh` directly (`--attach` to auto-attach).

### Auto-start on macOS (LaunchAgent)

If you want Symphony to start automatically at login and keep a launchd job running, point your
LaunchAgent command to `./scripts/run-symphony-launch-agent.sh` (without `--attach`).
That wrapper keeps watching the tmux session and recreates it if the session disappears.

Default startup chain:

1. `launchd` starts `./scripts/run-symphony-launch-agent.sh`
2. `run-symphony-launch-agent.sh` ensures tmux session `symphony` exists
3. `run-symphony-tmux.sh` injects `LINEAR_API_KEY` into tmux from the environment or macOS Keychain
4. `run-symphony.sh` starts cloudflared if needed, loads `LINEAR_API_KEY`, and launches Symphony

Before relying on auto-start, save the Linear token into Keychain once:

```bash
cd symphony/elixir
make linear-key
```

Example `ProgramArguments` command:

```bash
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; \
cd /Users/izutanikazuki/symphony-workspaces/symphony/elixir && \
./scripts/run-symphony-launch-agent.sh
```

Recommended `~/Library/LaunchAgents/local.symphony.tmux.plist` keys:

```xml
<key>KeepAlive</key>
<true/>
<key>RunAtLoad</key>
<true/>
```

After editing `~/Library/LaunchAgents/local.symphony.tmux.plist`, reload it:

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/local.symphony.tmux.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/local.symphony.tmux.plist
launchctl kickstart -k "gui/$(id -u)/local.symphony.tmux"
```

Useful runtime checks:

```bash
launchctl print "gui/$(id -u)/local.symphony.tmux"
tmux ls
tmux attach -t symphony
tail -f ~/Library/Logs/local.symphony.tmux.log
tail -f ~/Library/Logs/local.symphony.tmux.err.log
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

When using Linear webhooks, expose this server port publicly (for example via reverse proxy or
tunnel) and configure the endpoint URL in Linear.

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
webhooks:
  linear:
    enabled: true
    secret: $LINEAR_WEBHOOK_SECRET
polling:
  enabled: false
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

To monitor multiple Linear projects:

```md
---
tracker:
  kind: linear
  dirRoot: ~/symphony-workspaces
  projects:
    - slug: "filemakertraining-d0641848a5df"
      dir: fileMaker/training
    - slug: "symphony-4d878387ede9"
      dir: symphony
---
```

`projects[].slug` should use the Linear project `slugId` (the ID suffix after the last `-`
in the project URL slug, for example `.../project/<name>-<slugId>`).
`add-project.sh connect` accepts either full project URL/full slug or plain `slugId`, and
normalizes to `slugId`.

If `projects[].dir` is set, Symphony uses that path for the project workspace. Relative
paths are resolved from `tracker.dirRoot`. If `projects[].dir` is omitted, Symphony falls
back to `<dirRoot>/<project_name>`.

You can register or update one mapping from CLI:

```bash
cd elixir
mise exec -- mix workflow.projects.add --slug d0641848a5df --dir fileMaker/training
```

Or use the helper script:

```bash
bash ~/symphony-workspaces/symphony/elixir/add-project.sh new /Users/izutanikazuki/symphony-workspaces/symphony "Project Name"
bash ~/symphony-workspaces/symphony/elixir/add-project.sh connect . https://linear.app/mezame-ai/project/aqua-hp-99f897273ee0
```

`add-project.sh` commands:

- `new <dir> <project-name>`: creates a new Linear project in team key `MEZ`, then registers mapping
- `connect <dir> <linear-slug-or-url>`: registers mapping to an existing Linear project

When using `add-project.sh`, relative `dir` values (such as `.`, `./foo`, `../bar`) are
normalized and saved as absolute paths from the current working directory.

`new` requires `LINEAR_API_KEY`, `curl`, and `jq`. Team key can be overridden with `LINEAR_TEAM_KEY`.
If `LINEAR_API_KEY` is not exported, the script checks macOS Keychain using
`SYMPHONY_LINEAR_KEYCHAIN_SERVICE` / `SYMPHONY_LINEAR_KEYCHAIN_ACCOUNT` (same defaults as `make run-symphony`),
and also attempts one `dotenvx run` re-exec that searches `.env*` in the current directory,
script directory, and repo root.

Notes:

- If a value is missing, defaults are used.
- `tracker.project_slug` (single project) and `tracker.projects` (multi-project) are both supported.
  If `tracker.projects` is present, it is used for polling and workspace routing.
- `tracker.dirRoot` (or `tracker.dir_root`) sets the root for project workspace routing.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `codex.turn_sandbox_policy.type` values: `dangerFullAccess`, `readOnly`,
  `externalSandbox`, `workspaceWrite`.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.4"
```

- If `WORKFLOW.md` is missing or has invalid YAML, startup and scheduling are halted until fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, `/api/v1/refresh`, and `/api/v1/webhooks/linear`.
- `webhooks.linear.secret` reads from `LINEAR_WEBHOOK_SECRET` when unset or when value is `$LINEAR_WEBHOOK_SECRET`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

## FAQ

### What happens when an issue enters the Backoff queue?

In the Elixir reference implementation, a Backoff retry starts a new Codex app-server thread/session
for the issue, so conversation memory from the previous session is not preserved.

At the same time, the issue workspace on disk is reused (it is not recreated from scratch if the
directory already exists), so file changes in the workspace remain available for the retry.

Retry prompts are rebuilt from current Linear issue data and include the issue description plus
recent comments. In practice this means checklist/workpad progress can be re-read from Linear, but
there are fetch limits:

- comments are fetched with `first: 5`
- each comment body is truncated to 2,000 characters

If checklist state lives outside that fetched window, the agent may miss it unless it explicitly
retrieves additional context from Linear during the run.

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
