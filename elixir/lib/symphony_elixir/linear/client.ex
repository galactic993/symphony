defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @issue_comment_page_size 5
  @max_comment_body_chars 2_000
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $commentFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        project {
          slugId
          name
        }
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        attachments {
          nodes {
            id
            title
            url
            sourceType
          }
        }
        comments(first: $commentFirst) {
          nodes {
            id
            body
            createdAt
            updatedAt
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!, $commentFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        project {
          slugId
          name
        }
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        attachments {
          nodes {
            id
            title
            url
            sourceType
          }
        }
        comments(first: $commentFirst) {
          nodes {
            id
            body
            createdAt
            updatedAt
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    projects = Config.linear_projects()

    cond do
      is_nil(Config.linear_api_token()) ->
        {:error, :missing_linear_api_token}

      projects == [] ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_projects(projects, Config.linear_active_states(), assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      projects = Config.linear_projects()

      cond do
        is_nil(Config.linear_api_token()) ->
          {:error, :missing_linear_api_token}

        projects == [] ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_projects(projects, normalized_states, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  defp do_fetch_by_projects(projects, state_names, assignee_filter)
       when is_list(projects) and is_list(state_names) do
    projects
    |> Enum.reduce_while({:ok, []}, fn project, {:ok, acc_issues} ->
      case do_fetch_project_issues(project, state_names, assignee_filter) do
        {:ok, issues} -> {:cont, {:ok, acc_issues ++ issues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} ->
        {:ok, dedupe_issues_by_id(issues)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_fetch_project_issues(%{slug: project_slug}, state_names, assignee_filter)
       when is_binary(project_slug) do
    do_fetch_by_states(project_slug, state_names, assignee_filter)
  end

  defp do_fetch_project_issues(_project, _state_names, _assignee_filter) do
    {:ok, []}
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             commentFirst: @issue_comment_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter, project_slug) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp dedupe_issues_by_id(issues) when is_list(issues) do
    issues
    |> Enum.reduce({[], MapSet.new()}, fn issue, {acc, seen_ids} ->
      issue_id = Map.get(issue, :id)

      if is_binary(issue_id) and MapSet.member?(seen_ids, issue_id) do
        {acc, seen_ids}
      else
        {[issue | acc], if(is_binary(issue_id), do: MapSet.put(seen_ids, issue_id), else: seen_ids)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp do_fetch_issue_states(ids, assignee_filter) do
    case graphql(@query_by_ids, %{
           ids: ids,
           first: Enum.min([length(ids), @issue_page_size]),
           relationFirst: @issue_page_size,
           commentFirst: @issue_comment_page_size
         }) do
      {:ok, body} ->
        decode_linear_response(body, assignee_filter)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.linear_api_token() do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.linear_endpoint(),
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(response, assignee_filter, project_slug_override \\ nil)

  defp decode_linear_response(
         %{"data" => %{"issues" => %{"nodes" => nodes}}},
         assignee_filter,
         project_slug_override
       ) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter, project_slug_override))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter, _project_slug_override) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter, _project_slug_override) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter,
         project_slug_override
       ) do
    with {:ok, issues} <-
           decode_linear_response(
             %{"data" => %{"issues" => %{"nodes" => nodes}}},
             assignee_filter,
             project_slug_override
           ) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter, project_slug_override),
    do: decode_linear_response(response, assignee_filter, project_slug_override)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter, project_slug_override \\ nil)

  defp normalize_issue(issue, assignee_filter, project_slug_override) when is_map(issue) do
    assignee = issue["assignee"]
    project_slug = issue_project_slug(issue, project_slug_override)
    project_name = issue_project_name(issue)
    project_dir = Config.linear_project_dir(project_slug) || Config.project_workspace_dir(project_name)

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      project_slug: project_slug,
      project_name: project_name,
      project_dir: project_dir,
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      attachments: extract_attachments(issue),
      comments: extract_comments(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter, _project_slug_override), do: nil

  defp issue_project_slug(issue, project_slug_override) do
    case normalize_project_slug(project_slug_override || get_in(issue, ["project", "slugId"])) do
      nil -> Config.linear_project_slug()
      project_slug -> project_slug
    end
  end

  defp issue_project_name(issue) when is_map(issue) do
    case get_in(issue, ["project", "name"]) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          project_name -> project_name
        end

      _ ->
        nil
    end
  end

  defp normalize_project_slug(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_project_slug(_value), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.linear_assignee() do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_attachments(%{"attachments" => %{"nodes" => attachments}})
       when is_list(attachments) do
    attachments
    |> Enum.flat_map(fn
      %{"url" => url} = attachment when is_binary(url) ->
        trimmed_url = String.trim(url)

        if trimmed_url == "" do
          []
        else
          [
            %{
              id: attachment["id"],
              title: normalize_text_field(attachment["title"]),
              url: trimmed_url,
              source_type: normalize_text_field(attachment["sourceType"])
            }
          ]
        end

      _ ->
        []
    end)
  end

  defp extract_attachments(_), do: []

  defp extract_comments(%{"comments" => %{"nodes" => comments}}) when is_list(comments) do
    comments
    |> Enum.flat_map(fn
      %{"body" => body} = comment when is_binary(body) ->
        normalized_body =
          body
          |> String.trim()
          |> truncate_comment_body()

        if normalized_body == "" do
          []
        else
          [
            %{
              id: comment["id"],
              body: normalized_body,
              created_at: parse_datetime(comment["createdAt"]),
              updated_at: parse_datetime(comment["updatedAt"])
            }
          ]
        end

      _ ->
        []
    end)
    |> Enum.sort_by(fn comment ->
      created_at_unix =
        case comment.created_at do
          %DateTime{} = datetime -> DateTime.to_unix(datetime, :microsecond)
          _ -> -1
        end

      {created_at_unix, comment.id || ""}
    end)
  end

  defp extract_comments(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil

  defp normalize_text_field(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_text_field(_), do: nil

  defp truncate_comment_body(body) when is_binary(body) do
    if String.length(body) > @max_comment_body_chars do
      String.slice(body, 0, @max_comment_body_chars) <> "...<truncated>"
    else
      body
    end
  end
end
