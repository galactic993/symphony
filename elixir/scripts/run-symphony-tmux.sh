#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELIXIR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SESSION_NAME="${SYMPHONY_TMUX_SESSION:-symphony}"
WINDOW_NAME="${SYMPHONY_TMUX_WINDOW:-runner}"
RUN_COMMAND="${SYMPHONY_TMUX_RUN_COMMAND:-./scripts/run-symphony.sh}"
ATTACH="${1:-}"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required. Install: brew install tmux" >&2
  exit 1
fi

start_command="cd $(printf '%q' "${ELIXIR_DIR}") && ${RUN_COMMAND}"

if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
  tmux new-session -d -s "${SESSION_NAME}" -n "${WINDOW_NAME}" "${start_command}"
else
  if tmux list-windows -t "${SESSION_NAME}" -F "#{window_name}" | grep -Fxq "${WINDOW_NAME}"; then
    pane_id="$(tmux list-panes -t "${SESSION_NAME}:${WINDOW_NAME}" -F "#{pane_id}" | head -n 1)"
    pane_command="$(tmux display-message -p -t "${pane_id}" "#{pane_current_command}")"

    if [ "${pane_command}" = "bash" ] || [ "${pane_command}" = "zsh" ] || [ "${pane_command}" = "sh" ]; then
      tmux send-keys -t "${pane_id}" "${start_command}" C-m
    fi
  else
    tmux new-window -t "${SESSION_NAME}" -n "${WINDOW_NAME}" "${start_command}"
  fi
fi

if [ "${ATTACH}" = "--attach" ]; then
  exec tmux attach-session -t "${SESSION_NAME}"
fi

echo "tmux session ready: ${SESSION_NAME} (${WINDOW_NAME})"
echo "Attach: tmux attach -t ${SESSION_NAME}"
