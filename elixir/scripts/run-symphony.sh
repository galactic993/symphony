#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SYMPHONY_LINEAR_KEYCHAIN_SERVICE:-symphony.linear.api_key}"
ACCOUNT_NAME="${SYMPHONY_LINEAR_KEYCHAIN_ACCOUNT:-$USER}"

if ! command -v dotenvx >/dev/null 2>&1; then
  echo "dotenvx is required. Install: brew install dotenvx/brew/dotenvx" >&2
  exit 1
fi

LINEAR_API_KEY="$(security find-generic-password -s "$SERVICE_NAME" -a "$ACCOUNT_NAME" -w 2>/dev/null || true)"
if [ -z "${LINEAR_API_KEY}" ]; then
  echo "LINEAR_API_KEY not found in Keychain." >&2
  echo "Run: ./scripts/set-linear-api-key.sh" >&2
  exit 1
fi

exec dotenvx run -e "LINEAR_API_KEY=${LINEAR_API_KEY}" -- \
  mise exec -- ./bin/symphony ./WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  "$@"
