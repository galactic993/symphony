#!/usr/bin/env bash
set -euo pipefail

ORIGINAL_ARGS=("$@")
DOTENVX_REEXEC_FLAG="${SYMPHONY_ADD_PROJECT_DOTENVX_REEXEC:-0}"

usage() {
  cat <<'EOF'
Usage:
  add-project.sh connect <dir> <linear-slug-or-url>
  add-project.sh new <dir> <project-name>

Examples:
  bash add-project.sh new /Users/izutanikazuki/symphony-workspaces/symphony "Project Name"
  bash ~/symphony-workspaces/symphony/elixir/add-project.sh connect . https://linear.app/mezame-ai/project/aqua-hp-99f897273ee0

Notes:
  - `new` creates a Linear project under team key `MEZ` by default.
  - Relative `dir` values are saved as absolute paths from current working directory.
  - Override team key with `LINEAR_TEAM_KEY`.
  - If `LINEAR_API_KEY` is unset, script checks Keychain and tries `dotenvx run` once.
  - `new` requires `LINEAR_API_KEY`, `curl`, and `jq`.
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

  dotenv_args=(-e "SYMPHONY_ADD_PROJECT_DOTENVX_REEXEC=1")
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

ensure_linear_api_key() {
  load_linear_api_key_from_keychain || true
  reexec_with_dotenvx_if_possible

  if [[ -z "${LINEAR_API_KEY:-}" ]]; then
    if command -v dotenvx >/dev/null 2>&1; then
      error_exit 'LINEAR_API_KEY is required for "new" command (or run with `dotenvx run -- ...`, or set keychain via `make linear-key`)'
    fi

    error_exit 'LINEAR_API_KEY is required for "new" command (or set keychain via `make linear-key`)'
  fi
}

validate_project_dir() {
  local project_dir="$1"

  if [[ -z "${project_dir// }" ]]; then
    error_exit "dir must not be empty"
  fi
}

ensure_project_dir_exists() {
  local project_dir="$1"

  if [[ ! -e "$project_dir" ]]; then
    error_exit "dir does not exist: ${project_dir}"
  fi

  if [[ ! -d "$project_dir" ]]; then
    error_exit "dir is not a directory: ${project_dir}"
  fi
}

normalize_project_dir() {
  local input="$1"
  local merged_path=""
  local component=""
  local -a raw_parts
  local -a normalized_parts
  local normalized_path=""
  local idx

  if [[ "$input" == /* ]]; then
    merged_path="$input"
  else
    merged_path="$(pwd -P)/${input}"
  fi

  while [[ "$merged_path" == *"//"* ]]; do
    merged_path="${merged_path//\/\//\/}"
  done

  IFS='/' read -r -a raw_parts <<< "$merged_path"
  normalized_parts=()

  for component in "${raw_parts[@]}"; do
    case "$component" in
      "" | ".")
        ;;
      "..")
        if ((${#normalized_parts[@]} > 0)); then
          unset "normalized_parts[${#normalized_parts[@]}-1]"
        fi
        ;;
      *)
        normalized_parts+=("$component")
        ;;
    esac
  done

  if ((${#normalized_parts[@]} == 0)); then
    printf '/\n'
    return 0
  fi

  normalized_path=""
  for idx in "${!normalized_parts[@]}"; do
    normalized_path+="/${normalized_parts[$idx]}"
  done

  printf '%s\n' "$normalized_path"
}

normalize_slug() {
  local input="$1"
  local slug=""
  local slug_id_suffix=""

  if [[ "$input" == http://* || "$input" == https://* ]]; then
    if [[ "$input" != *"/project/"* ]]; then
      echo "Error: URL must contain /project/<slug>" >&2
      return 1
    fi

    local rest="${input#*"/project/"}"
    slug="${rest%%/*}"
    slug="${slug%%\?*}"
    slug="${slug%%\#*}"
  else
    slug="$input"
  fi

  if [[ -z "${slug// }" ]]; then
    error_exit "slug must not be empty"
  fi

  slug_id_suffix="${slug##*-}"
  if [[ "$slug_id_suffix" != "$slug" && "$slug_id_suffix" =~ ^[[:alnum:]]{8,}$ ]]; then
    slug="$slug_id_suffix"
  fi

  printf '%s\n' "$slug"
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
  local team_key="${LINEAR_TEAM_KEY:-MEZ}"
  local query='query SymphonyTeamByKey($key: String!) { teams(filter: { key: { eq: $key } }, first: 1) { nodes { id key name } } }'
  local variables_json
  local response
  local team_id

  ensure_linear_api_key
  require_command curl
  require_command jq

  variables_json="$(jq -nc --arg key "$team_key" '{key: $key}')"
  response="$(linear_graphql "$query" "$variables_json")"
  team_id="$(jq -r '.data.teams.nodes[0].id // empty' <<<"$response")"

  if [[ -z "$team_id" ]]; then
    error_exit "could not find Linear team key: ${team_key}"
  fi

  printf '%s\n' "$team_id"
}

create_linear_project() {
  local project_name="$1"
  local team_id="${2:-}"
  local query
  local variables_json
  local response
  local success
  local slug
  local project_url

  ensure_linear_api_key
  require_command curl
  require_command jq

  if [[ -z "${project_name// }" ]]; then
    error_exit "project name must not be empty"
  fi

  if [[ -z "$team_id" ]]; then
    team_id="$(resolve_team_id)"
  fi
  query='mutation SymphonyCreateProject($name: String!, $teamId: String!) { projectCreate(input: { name: $name, teamIds: [$teamId] }) { success project { name slugId url } } }'
  variables_json="$(jq -nc --arg name "$project_name" --arg teamId "$team_id" '{name: $name, teamId: $teamId}')"
  response="$(linear_graphql "$query" "$variables_json")"
  success="$(jq -r '.data.projectCreate.success // false' <<<"$response")"

  if [[ "$success" != "true" ]]; then
    error_exit "Linear project creation failed (`projectCreate.success` was false)"
  fi

  slug="$(jq -r '.data.projectCreate.project.slugId // empty' <<<"$response")"
  project_url="$(jq -r '.data.projectCreate.project.url // empty' <<<"$response")"

  if [[ -z "$slug" && -n "$project_url" ]]; then
    slug="$(normalize_slug "$project_url")"
  fi

  if [[ -z "$slug" ]]; then
    error_exit "created project slug was empty"
  fi

  echo "Created Linear project: name=${project_name} slug=${slug} team=${LINEAR_TEAM_KEY:-MEZ}" >&2
  printf '%s\n' "$slug"
}

# Workflow states required by symphony workflow (name:type:color)
SYMPHONY_WORKFLOW_STATES=(
  "Human Review:started:#f2c94c"
  "Rework:started:#e6e6e6"
  "Merging:started:#5b8def"
)

ensure_team_workflow_states() {
  local team_id="$1"
  local query
  local variables_json
  local response
  local existing_states
  local state_name
  local state_type
  local state_color
  local state_entry
  local success

  ensure_linear_api_key
  require_command curl
  require_command jq

  # Fetch existing workflow states for the team
  query='query SymphonyTeamWorkflowStates($teamId: String!) { team(id: $teamId) { states { nodes { name type } } } }'
  variables_json="$(jq -nc --arg teamId "$team_id" '{teamId: $teamId}')"
  response="$(linear_graphql "$query" "$variables_json")"
  existing_states="$(jq -r '.data.team.states.nodes // [] | map(.name) | @json' <<<"$response")"

  for state_entry in "${SYMPHONY_WORKFLOW_STATES[@]}"; do
    IFS=':' read -r state_name state_type state_color <<< "$state_entry"

    # Check if state already exists
    if jq -e --arg name "$state_name" 'index($name) != null' <<<"$existing_states" >/dev/null 2>&1; then
      echo "Workflow state '${state_name}' already exists in team" >&2
      continue
    fi

    # Create the workflow state (use string type, not enum)
    query='mutation SymphonyCreateWorkflowState($name: String!, $teamId: String!, $type: String!, $color: String!) { workflowStateCreate(input: { name: $name, teamId: $teamId, type: $type, color: $color }) { success workflowState { name type } } }'
    variables_json="$(jq -nc --arg name "$state_name" --arg teamId "$team_id" --arg type "$state_type" --arg color "$state_color" '{name: $name, teamId: $teamId, type: $type, color: $color}')"
    response="$(linear_graphql "$query" "$variables_json")"
    success="$(jq -r '.data.workflowStateCreate.success // false' <<<"$response")"

    if [[ "$success" != "true" ]]; then
      error_exit "failed to create workflow state '${state_name}'"
    else
      echo "Created workflow state: ${state_name}" >&2
    fi
  done
}

resolve_elixir_dir() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local direct="${script_dir}"
  local from_repo_root="${script_dir}/elixir"
  local from_workspace_root="${script_dir}/symphony/elixir"

  if [[ -f "${direct}/mix.exs" ]]; then
    printf '%s\n' "$direct"
    return 0
  fi

  if [[ -f "${from_workspace_root}/mix.exs" ]]; then
    printf '%s\n' "$from_workspace_root"
    return 0
  fi

  if [[ -f "${from_repo_root}/mix.exs" ]]; then
    printf '%s\n' "$from_repo_root"
    return 0
  fi

  echo "Error: could not find elixir workspace. Expected one of:" >&2
  echo "  - ${direct}" >&2
  echo "  - ${from_workspace_root}" >&2
  echo "  - ${from_repo_root}" >&2
  return 1
}

run_mapping_add() {
  local elixir_dir="$1"
  local slug="$2"
  local project_dir="$3"

  if command -v mise >/dev/null 2>&1; then
    (
      cd "$elixir_dir"
      exec mise exec -- mix workflow.projects.add --slug "$slug" --dir "$project_dir"
    )
  else
    (
      cd "$elixir_dir"
      exec mix workflow.projects.add --slug "$slug" --dir "$project_dir"
    )
  fi
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

command_name="$1"
shift

project_dir=""
slug=""

case "$command_name" in
  connect)
    if [[ $# -ne 2 ]]; then
      usage
      error_exit '"connect" requires 2 args: <dir> <linear-slug-or-url>'
    fi

    project_dir="$1"
    linear_slug_or_url="$2"
    validate_project_dir "$project_dir"
    project_dir="$(normalize_project_dir "$project_dir")"
    slug="$(normalize_slug "$linear_slug_or_url")"
    ;;
  new)
    if [[ $# -ne 2 ]]; then
      usage
      error_exit '"new" requires 2 args: <dir> <project-name>'
    fi

    project_dir="$1"
    project_name="$2"
    validate_project_dir "$project_dir"
    project_dir="$(normalize_project_dir "$project_dir")"
    team_id="$(resolve_team_id)"
    slug="$(create_linear_project "$project_name" "$team_id")"
    ensure_team_workflow_states "$team_id"
    ;;
  *)
    usage
    error_exit "unknown command: ${command_name}"
    ;;
esac

ensure_project_dir_exists "$project_dir"

elixir_dir="$(resolve_elixir_dir)"
run_mapping_add "$elixir_dir" "$slug" "$project_dir"
