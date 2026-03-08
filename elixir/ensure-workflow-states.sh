#!/usr/bin/env bash
set -euo pipefail

DOTENVX_REEXEC_FLAG="${SYMPHONY_ENSURE_WORKFLOW_STATES_DOTENVX_REEXEC:-0}"

usage() {
  cat <<'EOF'
Usage:
  ensure-workflow-states.sh [team-key-or-id ...]

Examples:
  bash ensure-workflow-states.sh
  bash ensure-workflow-states.sh MEZ
  bash ensure-workflow-states.sh bebe8753-255d-441c-8e1b-b76cad8da597

Notes:
  - With no args, the script updates the default team list used in this workspace.
  - Args may be Linear team keys such as `MEZ` or concrete team IDs.
EOF
}

error_exit() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || error_exit "required command not found: $command_name"
}

load_linear_api_key_from_keychain() {
  local service_name="${SYMPHONY_LINEAR_KEYCHAIN_SERVICE:-symphony.linear.api_key}"
  local account_name="${SYMPHONY_LINEAR_KEYCHAIN_ACCOUNT:-$USER}"
  local keychain_value

  if ! command -v security >/dev/null 2>&1; then
    return 1
  fi

  keychain_value="$(security find-generic-password -s "$service_name" -a "$account_name" -w 2>/dev/null || true)"
  if [[ -z "$keychain_value" ]]; then
    return 1
  fi

  LINEAR_API_KEY="$keychain_value"
  export LINEAR_API_KEY
  return 0
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

  dotenv_args=(-e "SYMPHONY_ENSURE_WORKFLOW_STATES_DOTENVX_REEXEC=1")
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

  exec dotenvx run "${dotenv_args[@]}" -- bash "$0" "$@"
}

ensure_linear_api_key() {
  load_linear_api_key_from_keychain || true
  reexec_with_dotenvx_if_possible

  if [[ -z "${LINEAR_API_KEY:-}" ]]; then
    if command -v dotenvx >/dev/null 2>&1; then
      error_exit 'LINEAR_API_KEY is required (or run with `dotenvx run -- ...`, or set keychain via `make linear-key`)'
    fi

    error_exit 'LINEAR_API_KEY is required (or set keychain via `make linear-key`)'
  fi
}

linear_graphql() {
  local query="$1"
  local variables_json="$2"
  local payload
  local response
  local http_status
  local body

  payload="$(jq -nc --arg query "$query" --argjson variables "$variables_json" '{query: $query, variables: $variables}')"
  response="$(
    curl -sS -w $'\n%{http_code}' \
      -X POST "https://api.linear.app/graphql" \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "$payload"
  )" || error_exit "failed to call Linear GraphQL API"

  http_status="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ ! "$http_status" =~ ^[0-9]{3}$ ]]; then
    error_exit "unexpected HTTP status from Linear GraphQL API: ${http_status}"
  fi

  if (( http_status < 200 || http_status >= 300 )); then
    echo "$body" >&2
    error_exit "Linear GraphQL API returned HTTP ${http_status}"
  fi

  if jq -e '.errors? | type == "array" and length > 0' >/dev/null 2>&1 <<<"$body"; then
    jq -r '.errors[]?.message // "Unknown Linear GraphQL error"' <<<"$body" >&2 || true
    error_exit "Linear GraphQL API returned errors"
  fi

  printf '%s\n' "$body"
}

resolve_team_id() {
  local team_ref="$1"
  local query
  local variables_json
  local response
  local team_id

  if [[ "$team_ref" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
    printf '%s\n' "$team_ref"
    return 0
  fi

  query='query SymphonyTeamByKey($key: String!) { teams(filter: { key: { eq: $key } }, first: 1) { nodes { id } } }'
  variables_json="$(jq -nc --arg key "$team_ref" '{key: $key}')"
  response="$(linear_graphql "$query" "$variables_json")"
  team_id="$(jq -r '.data.teams.nodes[0].id // empty' <<<"$response")"

  if [[ -z "$team_id" ]]; then
    error_exit "could not find Linear team: ${team_ref}"
  fi

  printf '%s\n' "$team_id"
}

# Workflow states required by symphony workflow (name:type:color)
SYMPHONY_WORKFLOW_STATES=(
  "Human Review:started:#f2c94c"
  "Rework:started:#e6e6e6"
  "Merging:started:#5b8def"
)

ensure_team_workflow_states() {
  local team_ref="$1"
  local team_id
  local query
  local variables_json
  local response
  local existing_states
  local state_name
  local state_type
  local state_color
  local state_entry
  local success

  team_id="$(resolve_team_id "$team_ref")"

  # Fetch existing workflow states for the team
  query='query SymphonyTeamWorkflowStates($teamId: String!) { team(id: $teamId) { states { nodes { name type } } } }'
  variables_json="$(jq -nc --arg teamId "$team_id" '{teamId: $teamId}')"
  response="$(linear_graphql "$query" "$variables_json")"
  existing_states="$(jq -r '.data.team.states.nodes // [] | map(.name) | @json' <<<"$response")"

  echo "Team ID: ${team_id}" >&2

  for state_entry in "${SYMPHONY_WORKFLOW_STATES[@]}"; do
    IFS=':' read -r state_name state_type state_color <<< "$state_entry"

    # Check if state already exists
    if jq -e --arg name "$state_name" 'index($name) != null' <<<"$existing_states" >/dev/null 2>&1; then
      echo "  ✓ '${state_name}' already exists" >&2
      continue
    fi

    # Create the workflow state (use string type, not enum)
    query='mutation SymphonyCreateWorkflowState($name: String!, $teamId: String!, $type: String!, $color: String!) { workflowStateCreate(input: { name: $name, teamId: $teamId, type: $type, color: $color }) { success workflowState { name type } } }'
    variables_json="$(jq -nc --arg name "$state_name" --arg teamId "$team_id" --arg type "$state_type" --arg color "$state_color" '{name: $name, teamId: $teamId, type: $type, color: $color}')"
    response="$(linear_graphql "$query" "$variables_json")"
    success="$(jq -r '.data.workflowStateCreate.success // false' <<<"$response")"

    if [[ "$success" != "true" ]]; then
      error_exit "failed to create workflow state '${state_name}' for team ${team_ref}"
    else
      echo "  ✓ Created '${state_name}'" >&2
    fi
  done
}

# Default team refs from the workspace
DEFAULT_TEAM_REFS=(
  "MEZ"
  "f0ed534f-3937-40d4-868b-638069197d4d"  # ando
  "075e833a-e7af-4fff-b7bc-fd335494227f"  # jbci-training-portal
  "13fa583a-52fb-47a5-a33b-ada08685def3"  # all
  "423f867f-3c69-49f2-b5c8-afdcf3076516"  # jbci-sales-portal
  "54b2001d-5864-481b-bee1-e1ca2e0953eb"  # super-agent
  "ffe2de2f-cff5-44de-9762-5c54f271c3fc"  # SpaceAgent
  "cffc9ce4-feb1-45cf-9a9e-a5c39c21340f"  # DXC
  "b4c056dd-4fb0-4a4a-a054-1d06e9d9d265"  # sales
  "eb74b4a7-b8bd-4581-bdf4-0ff1ef5e0450"  # bizdev
)

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

echo "=== Ensuring symphony workflow states for all teams ===" >&2
echo "" >&2

ensure_linear_api_key
require_command curl
require_command jq

if [[ $# -gt 0 ]]; then
  team_refs=("$@")
else
  team_refs=("${DEFAULT_TEAM_REFS[@]}")
fi

for team_ref in "${team_refs[@]}"; do
  ensure_team_workflow_states "${team_ref}"
  echo "" >&2
done

echo "=== Done! All teams have been updated with symphony workflow states. ===" >&2
