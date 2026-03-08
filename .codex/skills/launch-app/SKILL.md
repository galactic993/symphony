---
name: launch-app
description: Use when you need to boot a local application and verify that it is reachable. Trigger for requests like "launch-app", "run the app", "start the dev server", "boot the preview", "open the local site", or when UI/runtime validation requires a live local URL.
---

# Launch App

## Overview

Start the local application, wait until it is actually reachable, and return a usable URL plus enough runtime context to continue validation.

## Workflow

1. Identify the correct launch target before starting anything.
   - Read the repo hints first: `package.json`, `README`, framework config files, `Makefile`, `docker-compose.yml`, `Procfile`, and test config.
   - Prefer the documented dev command for interactive debugging.
   - If the repo has separate frontend and backend apps, pick the app that matches the validation request instead of starting everything by default.
2. Normalize runtime inputs.
   - Choose an explicit host and port when the stack allows it.
   - Prefer loopback bindings such as `127.0.0.1`.
   - Use environment overrides already supported by the app, for example `PORT`, `HOST`, `PLAYWRIGHT_PORT`, `VITE_PORT`, `NEXT_PORT`, or framework-specific flags.
   - Record the final command, host, port, cwd, and log path.
3. Start the app in a long-lived terminal session.
   - Use a PTY/background session for commands that keep running.
   - Write logs to a file when practical so failures can be inspected without losing earlier output.
   - Avoid daemonizing through custom shell hacks unless the repo already does so.
4. Wait for readiness instead of assuming startup succeeded.
   - Poll the local URL with `curl`, or use the app's health endpoint if one exists.
   - Accept readiness only after you get a successful HTTP response or another strong signal that the app is serving.
   - If startup fails, inspect the logs before retrying.
5. Report the live runtime clearly.
   - Return the URL, the launch command, the working directory, and where logs are being written.
   - Note the session id or process id if you intend to keep it running for later steps.
6. Shut it down when the validation step is complete unless the user or workflow clearly benefits from leaving it alive.

## Decision Rules

- Prefer `npm run dev`, `pnpm dev`, `yarn dev`, `mix phx.server`, `rails server`, or equivalent repo-native dev commands for interactive validation.
- Use preview/production-like commands only when dev mode is unavailable or specifically broken.
- Use container orchestration only when the repo documents it as the primary local path.
- If dependencies are missing but installable from the repo instructions, install only what is needed and note it.
- If secrets or external services are required and unavailable, stop and report the blocker instead of fabricating config.

## Verification

- Confirm the chosen URL responds locally.
- Capture one concrete proof of readiness:
  - HTTP status from `curl`
  - page title or HTML snippet
  - framework log line showing the bound address
- If this launch is part of UI validation, hand the URL off to the next step immediately so screenshots, Playwright checks, or walkthrough recording can use the same live server.

## Failure Handling

- Port conflict: choose a different explicit port and restart.
- Missing dependency: install or build only if the repo already expects that step.
- Crash loop: stop after inspecting the first useful error and summarize the blocker.
- Wrong app started: stop it and relaunch the correct target rather than keeping multiple unrelated servers alive.

## Output

Provide a concise handoff with:

- launch command
- cwd
- URL
- readiness proof
- log path
- whether the process is still running
