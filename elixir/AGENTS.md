# Symphony Elixir

This directory contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).

## Local Runtime Ops

- macOS auto-start uses `~/Library/LaunchAgents/local.symphony.tmux.plist`.
- Point that LaunchAgent to `scripts/run-symphony-launch-agent.sh`, not directly to
  `run-symphony-tmux.sh`, so launchd stays resident and recreates the tmux session when needed.
- Standard tmux session name for the local Symphony service is `symphony`.
- Keep `LINEAR_API_KEY` in dotenvx-managed env files for this repo, not macOS Keychain.
- `scripts/run-symphony-tmux.sh` forwards `LINEAR_API_KEY` into tmux when it is already present in
  the environment.
- `scripts/run-symphony.sh` owns the actual Symphony boot flow: cloudflared readiness,
  `dotenvx` re-exec, and `mise exec` launch.
- Useful checks:
  - `launchctl print gui/$(id -u)/local.symphony.tmux`
  - `tmux attach -t symphony`
  - `tail -f ~/Library/Logs/local.symphony.tmux.log`
  - `tail -f ~/Library/Logs/local.symphony.tmux.err.log`


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

```bash
make all
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
