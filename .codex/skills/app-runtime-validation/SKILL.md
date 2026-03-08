---
name: app-runtime-validation
description: Use when you need to validate an app-touching change by actually driving the UI in a browser, recording proof, and posting that proof to the related Linear issue. Trigger for requests like "app-runtime-validation", "run browser QA", "validate the UI", "record a walkthrough", "upload the validation video to Linear", or whenever a ticket changes frontend screens, LiveView flows, routing, forms, browser-visible behavior, or other user-facing runtime paths.
---

# App Runtime Validation

## Overview

Deploy the latest code to the development environment, exercise the changed flow in a real browser against that environment, keep the resulting media artifact, and publish that proof to Linear. Treat this skill as mandatory for app-touching work before moving the issue to `Human Review`.

## Required Outcome

Validation is complete only when all of the following are true:

- the chosen development environment is confirmed reachable
- the latest code is deployed to the development environment that will be validated
- the changed flow was exercised in a browser, not inferred only from code or tests
- a fresh local video or screenshot artifact exists for the latest code
- at least one proof artifact is uploaded to the Linear issue
- the Linear workpad or validation notes mention what was exercised and where the artifact lives

## Workflow

1. Resolve the exact runtime scope.
   - Read the Linear issue, workpad `Validation`, acceptance criteria, and any PR `Manual QA` note.
   - Identify the narrowest browser walkthrough that proves the changed behavior.
   - Treat browser-visible behavior broadly: screens, navigation, forms, dialogs, onboarding, auth UX, LiveView updates, and any user-facing runtime path.
2. Deploy the latest code to the development environment first.
   - Use the repo-native deploy path for the current change: deployment CLI, CI workflow, preview environment, or other documented dev-environment release step.
   - Wait until the deployment completes and the target environment is serving the latest commit.
   - Record the environment name, deployed URL, deployed commit/branch, and any deployment run URL or log reference.
   - If the repository explicitly treats a local runtime as the development environment, use `$launch-app` here and record that the deployment target is local.
3. Confirm the validation target is ready.
   - Open the deployed URL or health endpoint and wait for a real success signal.
   - If multiple apps exist, validate only the app and route affected by the changed flow.
   - Do not start browser walkthroughs against stale or partially rolled-out environments.
4. Drive the browser with recording enabled.
   - Prefer `js_repl` with Playwright because it can automate the browser and save artifacts in one flow.
   - Launch a fresh browser context with `recordVideo` enabled.
   - Exercise the changed flow end-to-end using deterministic selectors and assertions.
   - Wait for explicit UI signals instead of relying on fixed sleeps.
5. Preserve useful artifacts.
   - Close the browser context cleanly so the recorded video is flushed to disk.
   - Save screenshots at key checkpoints when they make review faster.
   - Record the final local paths for the video, screenshots, traces, and any supporting logs.
6. Publish proof to Linear.
   - Prefer `linear_upload_issue_asset` to upload the video or screenshot directly to the issue and create a short comment.
   - Use the comment body to state the environment, deployed commit, walked flow, and whether it passed.
   - If `linear_upload_issue_asset` is unavailable but `linear_graphql` is present, follow `$linear` upload flow and create the comment manually.
7. Mirror to the PR only when useful.
   - If reviewers also need PR evidence, call `$github-pr-media` after the Linear upload and reuse the same durable URL.
   - PR media is optional. Linear evidence is required.
8. Update the workpad.
   - Add the executed flow, deployment target, deployed URL, deployed commit, artifact path, and Linear asset URL to the `Validation` and `Notes` sections.
   - Do not mark the ticket ready for `Human Review` until this is done.

## Playwright Pattern

Use `js_repl` so the validation stays reproducible and the browser can be driven directly:

```js
// codex-js-repl: timeout_ms=120000
const { chromium } = await import("playwright");
const artifactDir = "/tmp/app-runtime-validation";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  recordVideo: {
    dir: artifactDir,
    size: { width: 1440, height: 900 }
  }
});
const page = await context.newPage();

await page.goto("https://dev.example.test", { waitUntil: "networkidle" });
await page.getByRole("button", { name: "Save" }).click();
await page.getByText("Saved").waitFor();
await page.screenshot({ path: `${artifactDir}/saved-state.png`, fullPage: true });

await context.close();
await browser.close();
```

Replace the URL, selectors, and assertions with the real flow under test. Always close the context before reading the video file path.

## Linear Comment Shape

Keep the upload comment short and reviewer-facing:

```md
Runtime validation for MEZ-123

- Environment: development env at https://dev.example.test
- Commit: b86fc86
- Flow: create draft -> review summary -> save
- Result: passed
```

`linear_upload_issue_asset` appends the uploaded asset URL automatically. If validation fails, upload the best failure artifact you have and do not move the issue forward.

## Guardrails

- Do not skip browser validation just because unit or integration tests passed.
- Do not skip the deployment step and validate an older environment snapshot.
- Do not reuse stale artifacts from a previous commit. Rerun on the current HEAD.
- Do not upload private or unsafe data without checking what is visible in the media.
- Do not leave long-lived dev servers or browsers running unnecessarily after validation finishes.
- If login, fixtures, or feature flags are required, set up only the minimum needed state and document it in the workpad.
- If the latest code cannot be deployed, or the browser flow cannot be exercised because of missing secrets, broken seed data, broken rollout, or missing auth/tooling, record the blocker explicitly instead of silently waiving validation.
