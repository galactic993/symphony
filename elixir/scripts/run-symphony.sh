#!/usr/bin/env bash
set -euo pipefail

ORIGINAL_ARGS=("$@")
DOTENVX_REEXEC_FLAG="${SYMPHONY_RUN_SYMPHONY_DOTENVX_REEXEC:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELIXIR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ELIXIR_DIR}"

SYMPHONY_CLOUDFLARED_ENABLED="${SYMPHONY_CLOUDFLARED_ENABLED:-1}"
SYMPHONY_CLOUDFLARED_TUNNEL="${SYMPHONY_CLOUDFLARED_TUNNEL:-symphony-webhook}"
SYMPHONY_CLOUDFLARED_LOG="${SYMPHONY_CLOUDFLARED_LOG:-/tmp/symphony-cloudflared.log}"
SYMPHONY_CLOUDFLARED_WAIT_SECONDS="${SYMPHONY_CLOUDFLARED_WAIT_SECONDS:-20}"
SYMPHONY_BIN_PATH="${ELIXIR_DIR}/bin/symphony"

log() {
  echo "[run-symphony] $*"
}

reexec_with_dotenvx_if_possible() {
  local script_dir
  local repo_root
  local -a candidate_dirs
  local -a dotenv_args
  local candidate
  local file_path

  if [[ -n "${LINEAR_API_KEY:-}" ]]; then
    return 0
  fi

  if [[ "$DOTENVX_REEXEC_FLAG" == "1" ]]; then
    return 0
  fi

  if ! command -v dotenvx >/dev/null 2>&1; then
    return 0
  fi

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"
  candidate_dirs=("$PWD")

  if [[ "$script_dir" != "$PWD" ]]; then
    candidate_dirs+=("$script_dir")
  fi

  if [[ "$repo_root" != "$PWD" && "$repo_root" != "$script_dir" ]]; then
    candidate_dirs+=("$repo_root")
  fi

  dotenv_args=(-e "SYMPHONY_RUN_SYMPHONY_DOTENVX_REEXEC=1")
  for candidate in "${candidate_dirs[@]}"; do
    file_path="${candidate}/.env"
    [[ -f "$file_path" ]] && dotenv_args+=(-f "$file_path")

    file_path="${candidate}/.env.local"
    [[ -f "$file_path" ]] && dotenv_args+=(-f "$file_path")

    file_path="${candidate}/.env.development"
    [[ -f "$file_path" ]] && dotenv_args+=(-f "$file_path")

    file_path="${candidate}/.env.production"
    [[ -f "$file_path" ]] && dotenv_args+=(-f "$file_path")

    file_path="${candidate}/.env.vault"
    [[ -f "$file_path" ]] && dotenv_args+=(-fv "$file_path")

    file_path="${candidate}/.env.keys"
    [[ -f "$file_path" ]] && dotenv_args+=(-fk "$file_path")
  done

  exec dotenvx run "${dotenv_args[@]}" -- bash "$0" "${ORIGINAL_ARGS[@]}"
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

skip_if_already_running() {
  local running_pids
  running_pids="$(pgrep -f "${SYMPHONY_BIN_PATH}" || true)"

  if [ -n "${running_pids}" ]; then
    log "symphony is already running (pid: ${running_pids//$'\n'/, }). skip duplicate startup."
    exit 0
  fi
}

if ! command -v dotenvx >/dev/null 2>&1; then
  echo "dotenvx is required. Install: brew install dotenvx/brew/dotenvx" >&2
  exit 1
fi

skip_if_already_running

ensure_cloudflared_tunnel_ready

LINEAR_API_KEY="${LINEAR_API_KEY:-}"

reexec_with_dotenvx_if_possible

if [ -z "${LINEAR_API_KEY}" ]; then
  echo "LINEAR_API_KEY is not set." >&2
  echo "Set it in the current shell or via dotenvx-managed env files such as .env." >&2
  echo "Run: ./scripts/set-linear-api-key.sh" >&2
  exit 1
fi

export LINEAR_API_KEY

exec dotenvx run -- \
  mise exec -- ./bin/symphony ./WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  "$@"
