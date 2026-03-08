#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELIXIR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ELIXIR_DIR}"

SERVICE_NAME="${SYMPHONY_LINEAR_KEYCHAIN_SERVICE:-symphony.linear.api_key}"
ACCOUNT_NAME="${SYMPHONY_LINEAR_KEYCHAIN_ACCOUNT:-$USER}"
SYMPHONY_CLOUDFLARED_ENABLED="${SYMPHONY_CLOUDFLARED_ENABLED:-1}"
SYMPHONY_CLOUDFLARED_TUNNEL="${SYMPHONY_CLOUDFLARED_TUNNEL:-symphony-webhook}"
SYMPHONY_CLOUDFLARED_LOG="${SYMPHONY_CLOUDFLARED_LOG:-/tmp/symphony-cloudflared.log}"
SYMPHONY_CLOUDFLARED_WAIT_SECONDS="${SYMPHONY_CLOUDFLARED_WAIT_SECONDS:-20}"

log() {
  echo "[run-symphony] $*"
}

ensure_cloudflared_tunnel_ready() {
  if [ "${SYMPHONY_CLOUDFLARED_ENABLED}" != "1" ]; then
    return 0
  fi

  if ! [[ "${SYMPHONY_CLOUDFLARED_WAIT_SECONDS}" =~ ^[0-9]+$ ]]; then
    echo "SYMPHONY_CLOUDFLARED_WAIT_SECONDS must be a non-negative integer." >&2
    exit 1
  fi

  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "cloudflared is required when SYMPHONY_CLOUDFLARED_ENABLED=1." >&2
    echo "Install: brew install cloudflare/cloudflare/cloudflared" >&2
    exit 1
  fi

  local matcher="cloudflared tunnel run ${SYMPHONY_CLOUDFLARED_TUNNEL}"
  if pgrep -f "${matcher}" >/dev/null 2>&1; then
    log "cloudflared tunnel already running: ${SYMPHONY_CLOUDFLARED_TUNNEL}"
  else
    log "starting cloudflared tunnel: ${SYMPHONY_CLOUDFLARED_TUNNEL}"
    nohup cloudflared tunnel run "${SYMPHONY_CLOUDFLARED_TUNNEL}" >>"${SYMPHONY_CLOUDFLARED_LOG}" 2>&1 &
    local tunnel_pid=$!
    sleep 1
    if ! kill -0 "${tunnel_pid}" >/dev/null 2>&1; then
      echo "cloudflared failed to start. Check ${SYMPHONY_CLOUDFLARED_LOG}" >&2
      tail -n 20 "${SYMPHONY_CLOUDFLARED_LOG}" >&2 || true
      exit 1
    fi
  fi

  local deadline=$((SECONDS + SYMPHONY_CLOUDFLARED_WAIT_SECONDS))
  local ready=0
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    if cloudflared tunnel info "${SYMPHONY_CLOUDFLARED_TUNNEL}" 2>/dev/null | grep -q "CONNECTOR ID"; then
      ready=1
      break
    fi
    sleep 1
  done

  if [ "${ready}" -ne 1 ]; then
    echo "cloudflared tunnel did not become ready within ${SYMPHONY_CLOUDFLARED_WAIT_SECONDS}s." >&2
    echo "Check: cloudflared tunnel info ${SYMPHONY_CLOUDFLARED_TUNNEL}" >&2
    echo "Log: ${SYMPHONY_CLOUDFLARED_LOG}" >&2
    exit 1
  fi

  log "cloudflared tunnel ready: ${SYMPHONY_CLOUDFLARED_TUNNEL}"
}

if ! command -v dotenvx >/dev/null 2>&1; then
  echo "dotenvx is required. Install: brew install dotenvx/brew/dotenvx" >&2
  exit 1
fi

ensure_cloudflared_tunnel_ready

LINEAR_API_KEY="${LINEAR_API_KEY:-}"
if [ -z "${LINEAR_API_KEY}" ]; then
  LINEAR_API_KEY="$(security find-generic-password -s "${SERVICE_NAME}" -a "${ACCOUNT_NAME}" -w 2>/dev/null || true)"
fi

if [ -z "${LINEAR_API_KEY}" ]; then
  echo "LINEAR_API_KEY is not set and was not found in Keychain." >&2
  echo "Run: ./scripts/set-linear-api-key.sh" >&2
  exit 1
fi

export LINEAR_API_KEY

exec dotenvx run -- \
  mise exec -- ./bin/symphony ./WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  "$@"
