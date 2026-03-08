---
name: github-pr-media
description: Use when you need to attach screenshots, videos, or other visual QA evidence to a GitHub pull request. Trigger for requests like "github-pr-media", "add screenshots to the PR", "attach a walkthrough video", "update Manual QA evidence", or when app validation should leave proof on the current PR.
---

# GitHub PR Media

## Overview

Publish visual evidence for the current GitHub PR and leave a reviewer-friendly comment or comment update that points to durable media URLs.

## Workflow

1. Resolve PR context first.
   - Use `gh pr view` to get the current PR number, URL, head branch, title, and existing comments.
   - If there is no current PR, stop and report that blocker before preparing media.
2. Gather candidate media.
   - Prefer files already produced by the validation flow: Playwright screenshots, videos, traces, logs, or manually captured assets.
   - Keep the asset list small and reviewer-oriented. One screenshot per state transition is usually enough.
   - Record each file path, what it demonstrates, and whether it is image or video.
3. Choose a publication route in this order.
   - If the environment already provides a direct uploader for GitHub PR media, use it.
   - Else if the media already has a durable URL, reuse that URL.
     - Examples: Linear upload URL, object storage URL, preview deployment URL.
   - Else if the asset is a small static image and the repo tolerates committed proof artifacts, add it under `.github/media/pr-<number>/` or `.github/media/<branch>/`, push it, and use the raw GitHub URL.
   - Do not commit large transient videos by default. For video, prefer a durable external URL and link to it from the PR comment.
4. Update PR evidence in one place.
   - Prefer a single marker comment such as `## Manual QA Evidence` or update the existing `Manual QA Plan`/evidence comment if the repo already uses one.
   - Avoid posting duplicate evidence comments on every iteration.
   - Include short bullets that map each asset to the behavior it proves.
5. Verify the rendered links.
   - Confirm every referenced URL is reachable.
   - For images, prefer Markdown image embeds.
   - For videos, use a labeled bullet link unless the hosting route supports rich embedding.

## Comment Structure

Use concise reviewer-facing text:

```md
## Manual QA Evidence

- Login flow screenshot
  - Proves the updated sign-in screen renders without layout regressions.
  - Asset: ![Login flow](<image-url>)
- Upload walkthrough video
  - Proves the end-to-end upload path completes successfully.
  - Asset: <video-url>
```

Keep the explanation tied to acceptance criteria, not to internal debugging chatter.

## Guardrails

- Never overwrite or delete human-authored comments unless explicitly asked.
- Prefer editing a single Codex-authored evidence comment instead of creating new ones repeatedly.
- Do not commit bulky or sensitive media into the repo just to make a URL.
- If the only available durable host is Linear, it is acceptable to link the Linear-hosted asset from the PR comment.
- If the asset contains secrets, personal data, or internal-only screens, stop and ask before publishing it anywhere durable.

## GitHub Operations

- Read PR comments with `gh pr view --comments` or `gh api` when you need comment ids.
- Create a new issue-style PR comment with `gh pr comment --body-file <file>`.
- Update an existing PR issue comment with:
  - `gh api repos/<owner>/<repo>/issues/comments/<comment_id> --method PATCH --field body@<file>`
- If you publish repo-hosted media, push the branch before writing the final comment so the raw URLs resolve for reviewers.

## Output

Report:

- which PR was updated
- which media files were published
- which URLs were used
- whether the evidence comment was created or updated
- any fallback taken, for example "linked Linear-hosted video because no direct GitHub media uploader was available"
