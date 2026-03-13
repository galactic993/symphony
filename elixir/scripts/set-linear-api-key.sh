#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELIXIR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE_PATH="${ELIXIR_DIR}/.env"
ENV_KEYS_FILE_PATH="${ELIXIR_DIR}/.env.keys"

printf "Enter LINEAR_API_KEY (input hidden): "
stty -echo
IFS= read -r LINEAR_API_KEY
stty echo
printf "\n"

if [ -z "${LINEAR_API_KEY}" ]; then
  echo "LINEAR_API_KEY is empty; aborting." >&2
  exit 1
fi

if ! command -v dotenvx >/dev/null 2>&1; then
  echo "dotenvx is required. Install: brew install dotenvx/brew/dotenvx" >&2
  exit 1
fi

dotenvx set LINEAR_API_KEY "${LINEAR_API_KEY}" \
  -f "${ENV_FILE_PATH}" \
  -fk "${ENV_KEYS_FILE_PATH}" \
  >/dev/null

echo "Saved LINEAR_API_KEY to ${ENV_FILE_PATH} using dotenvx encryption."
echo "Symphony will load it through dotenvx."
