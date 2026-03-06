#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SYMPHONY_LINEAR_KEYCHAIN_SERVICE:-symphony.linear.api_key}"
ACCOUNT_NAME="${SYMPHONY_LINEAR_KEYCHAIN_ACCOUNT:-$USER}"

printf "Enter LINEAR_API_KEY (input hidden): "
stty -echo
IFS= read -r LINEAR_API_KEY
stty echo
printf "\n"

if [ -z "${LINEAR_API_KEY}" ]; then
  echo "LINEAR_API_KEY is empty; aborting." >&2
  exit 1
fi

# Replace existing secret for this service/account pair.
security delete-generic-password -s "$SERVICE_NAME" -a "$ACCOUNT_NAME" >/dev/null 2>&1 || true
security add-generic-password -U -s "$SERVICE_NAME" -a "$ACCOUNT_NAME" -w "$LINEAR_API_KEY" >/dev/null

echo "Saved LINEAR_API_KEY to macOS Keychain."
echo "service=$SERVICE_NAME account=$ACCOUNT_NAME"
