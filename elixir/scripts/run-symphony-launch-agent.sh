#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELIXIR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SESSION_NAME="${SYMPHONY_TMUX_SESSION:-symphony}"
CHECK_INTERVAL_SECONDS="${SYMPHONY_LAUNCH_AGENT_CHECK_INTERVAL_SECONDS:-30}"

if ! [[ "${CHECK_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]] || [ "${CHECK_INTERVAL_SECONDS}" -lt 1 ]; then
  echo "SYMPHONY_LAUNCH_AGENT_CHECK_INTERVAL_SECONDS must be a positive integer." >&2
  exit 1
fi

cleanup() {
  exit 0
}

trap cleanup INT TERM

cd "${ELIXIR_DIR}"

while true; do
  ./scripts/run-symphony-tmux.sh

  while tmux has-session -t "${SESSION_NAME}" 2>/dev/null; do
    sleep "${CHECK_INTERVAL_SECONDS}"
  done

  echo "[launch-agent] tmux session '${SESSION_NAME}' is missing; recreating..."
done
