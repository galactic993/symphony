defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @linear_upload_issue_asset_tool "linear_upload_issue_asset"
  @linear_upload_issue_asset_description """
  Upload a local file to Linear and create an issue comment that references the uploaded asset.
  """
  @linear_upload_issue_asset_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issueId", "path"],
    "properties" => %{
      "issueId" => %{
        "type" => "string",
        "description" => "Linear issue internal id or ticket key, for example `MEZ-153`."
      },
      "path" => %{
        "type" => "string",
        "description" => "Absolute or cwd-relative path to the local file to upload."
      },
      "commentBody" => %{
        "type" => "string",
        "description" => "Optional text for the created comment. Use `{{asset_url}}` to control where the uploaded asset URL is inserted."
      },
      "contentType" => %{
        "type" => "string",
        "description" => "Optional MIME type. When omitted, Symphony infers a sensible default from the filename."
      },
      "makePublic" => %{
        "type" => "boolean",
        "description" => "Whether Linear should mark the uploaded asset as public. Defaults to false."
      }
    }
  }
  @resolve_issue_query """
  query SymphonyResolveIssue($issueId: String!) {
    issue(id: $issueId) {
      id
      identifier
    }
  }
  """
  @file_upload_mutation """
  mutation SymphonyFileUpload($filename: String!, $contentType: String!, $size: Int!, $makePublic: Boolean) {
    fileUpload(
      filename: $filename
      contentType: $contentType
      size: $size
      makePublic: $makePublic
    ) {
      success
      uploadFile {
        uploadUrl
        assetUrl
        headers {
          key
          value
        }
      }
    }
  }
  """
  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
        url
      }
    }
  }
  """
  @max_linear_upload_size 2_147_483_647

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @linear_upload_issue_asset_tool ->
        execute_linear_upload_issue_asset(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @linear_upload_issue_asset_tool,
        "description" => @linear_upload_issue_asset_description,
        "inputSchema" => @linear_upload_issue_asset_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_upload_issue_asset(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    upload_request = Keyword.get(opts, :upload_request, &upload_file_request/3)

    with {:ok, normalized_upload} <-
           normalize_linear_upload_arguments(arguments),
         {:ok, file_info} <-
           resolve_upload_file(
             normalized_upload.path,
             normalized_upload.content_type
           ),
         {:ok, issue} <- resolve_issue(normalized_upload.issue_ref, linear_client),
         {:ok, upload} <-
           request_file_upload(file_info, normalized_upload.make_public, linear_client),
         :ok <- upload_request.(upload.upload_url, upload.headers, file_info),
         {:ok, comment} <-
           create_issue_comment(
             issue.id,
             build_asset_comment_body(normalized_upload.comment_body, upload.asset_url),
             linear_client
           ) do
      success_response(%{
        "assetUrl" => upload.asset_url,
        "commentId" => comment.id,
        "commentUrl" => comment.url,
        "contentType" => file_info.content_type,
        "issueId" => issue.id,
        "issueIdentifier" => issue.identifier,
        "path" => file_info.path
      })
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_linear_upload_arguments(arguments) when is_map(arguments) do
    issue_ref =
      map_value(arguments, "issueId", :issueId) ||
        map_value(arguments, "issueKey", :issueKey) ||
        map_value(arguments, "issueIdOrKey", :issueIdOrKey)

    path = map_value(arguments, "path", :path)
    comment_body = map_value(arguments, "commentBody", :commentBody)
    content_type = map_value(arguments, "contentType", :contentType)
    make_public = map_value(arguments, "makePublic", :makePublic)

    with {:ok, normalized_issue_ref} <- normalize_required_string(issue_ref, :missing_issue_id),
         {:ok, normalized_path} <- normalize_required_string(path, :missing_path),
         {:ok, normalized_comment_body} <-
           normalize_optional_string(comment_body, :invalid_upload_comment_body),
         {:ok, normalized_content_type} <-
           normalize_optional_string(content_type, :invalid_upload_content_type),
         {:ok, normalized_make_public} <-
           normalize_optional_boolean(make_public, false, :invalid_upload_make_public) do
      build_normalized_upload_arguments_result(
        normalized_issue_ref,
        normalized_path,
        normalized_comment_body,
        normalized_content_type,
        normalized_make_public
      )
    end
  end

  defp normalize_linear_upload_arguments(_arguments), do: {:error, :invalid_upload_arguments}

  defp build_normalized_upload_arguments_result(
         normalized_issue_ref,
         normalized_path,
         normalized_comment_body,
         normalized_content_type,
         normalized_make_public
       ) do
    {:ok,
     %{
       issue_ref: normalized_issue_ref,
       path: normalized_path,
       comment_body: normalized_comment_body,
       content_type: normalized_content_type,
       make_public: normalized_make_public
     }}
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp normalize_required_string(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_required_string(_value, error), do: {:error, error}

  defp normalize_optional_string(nil, _error), do: {:ok, nil}

  defp normalize_optional_string(value, _error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_optional_string(_value, error), do: {:error, error}

  defp normalize_optional_boolean(nil, default, _error), do: {:ok, default}
  defp normalize_optional_boolean(value, _default, _error) when is_boolean(value), do: {:ok, value}
  defp normalize_optional_boolean(_value, _default, error), do: {:error, error}

  defp map_value(arguments, string_key, atom_key) do
    cond do
      Map.has_key?(arguments, string_key) -> Map.get(arguments, string_key)
      Map.has_key?(arguments, atom_key) -> Map.get(arguments, atom_key)
      true -> nil
    end
  end

  defp resolve_upload_file(path, content_type) when is_binary(path) do
    expanded_path = Path.expand(path)

    case File.stat(expanded_path) do
      {:ok, %{type: :regular, size: size}} when size <= @max_linear_upload_size ->
        {:ok,
         %{
           content_type: normalize_upload_content_type(content_type, expanded_path),
           filename: Path.basename(expanded_path),
           path: expanded_path,
           size: size
         }}

      {:ok, %{type: :regular, size: size}} ->
        {:error, {:upload_file_too_large, size}}

      {:ok, _stat} ->
        {:error, {:upload_path_not_regular_file, expanded_path}}

      {:error, :enoent} ->
        {:error, {:upload_file_not_found, expanded_path}}

      {:error, reason} ->
        {:error, {:upload_file_stat_failed, expanded_path, reason}}
    end
  end

  defp normalize_upload_content_type(nil, path), do: infer_content_type(path)
  defp normalize_upload_content_type(content_type, _path), do: content_type

  @content_types_by_extension %{
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".json" => "application/json",
    ".log" => "text/plain",
    ".mov" => "video/quicktime",
    ".mp4" => "video/mp4",
    ".png" => "image/png",
    ".txt" => "text/plain",
    ".webm" => "video/webm"
  }

  defp infer_content_type(path) when is_binary(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> then(&Map.get(@content_types_by_extension, &1, "application/octet-stream"))
  end

  defp resolve_issue(issue_ref, linear_client) do
    with {:ok, response} <- linear_client.(@resolve_issue_query, %{issueId: issue_ref}, []),
         :ok <- ensure_graphql_success(response),
         %{"id" => issue_id} = issue when is_binary(issue_id) <- get_in(response, ["data", "issue"]) do
      {:ok,
       %{
         id: issue_id,
         identifier: issue["identifier"] || issue_ref
       }}
    else
      nil ->
        {:error, :linear_issue_not_found}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :linear_issue_not_found}
    end
  end

  defp request_file_upload(file_info, make_public, linear_client) do
    variables = %{
      contentType: file_info.content_type,
      filename: file_info.filename,
      makePublic: make_public,
      size: file_info.size
    }

    with {:ok, response} <- linear_client.(@file_upload_mutation, variables, []),
         :ok <- ensure_graphql_success(response),
         true <- get_in(response, ["data", "fileUpload", "success"]) == true,
         %{"uploadUrl" => upload_url, "assetUrl" => asset_url} = upload
         when is_binary(upload_url) and is_binary(asset_url) <-
           get_in(response, ["data", "fileUpload", "uploadFile"]) do
      {:ok,
       %{
         asset_url: asset_url,
         headers: normalize_upload_headers(upload["headers"], file_info.content_type),
         upload_url: upload_url
       }}
    else
      false ->
        {:error, :linear_file_upload_failed}

      nil ->
        {:error, :linear_file_upload_failed}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :linear_file_upload_failed}
    end
  end

  defp normalize_upload_headers(headers, content_type) when is_list(headers) do
    normalized =
      headers
      |> Enum.reduce([], fn
        %{"key" => key, "value" => value}, acc when is_binary(key) and is_binary(value) ->
          [{key, value} | acc]

        %{key: key, value: value}, acc when is_binary(key) and is_binary(value) ->
          [{key, value} | acc]

        _, acc ->
          acc
      end)
      |> Enum.reverse()

    if Enum.any?(normalized, fn {key, _value} -> String.downcase(key) == "content-type" end) do
      normalized
    else
      [{"content-type", content_type} | normalized]
    end
  end

  defp normalize_upload_headers(_headers, content_type), do: [{"content-type", content_type}]

  defp upload_file_request(upload_url, headers, %{path: path}) when is_binary(upload_url) do
    case File.read(path) do
      {:ok, body} ->
        case Req.put(upload_url,
               headers: headers,
               body: body,
               connect_options: [timeout: 30_000],
               receive_timeout: 120_000
             ) do
          {:ok, %{status: status}} when status in 200..299 ->
            :ok

          {:ok, %{status: status}} ->
            {:error, {:linear_upload_status, status}}

          {:error, reason} ->
            {:error, {:linear_upload_request, reason}}
        end

      {:error, reason} ->
        {:error, {:upload_file_read_failed, path, reason}}
    end
  end

  defp create_issue_comment(issue_id, body, linear_client) do
    with {:ok, response} <- linear_client.(@create_comment_mutation, %{issueId: issue_id, body: body}, []),
         :ok <- ensure_graphql_success(response),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true,
         %{"id" => comment_id} = comment when is_binary(comment_id) <-
           get_in(response, ["data", "commentCreate", "comment"]) do
      {:ok,
       %{
         id: comment_id,
         url: comment["url"]
       }}
    else
      false ->
        {:error, :linear_comment_create_failed}

      nil ->
        {:error, :linear_comment_create_failed}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :linear_comment_create_failed}
    end
  end

  defp build_asset_comment_body(nil, asset_url), do: asset_url

  defp build_asset_comment_body(comment_body, asset_url) do
    if String.contains?(comment_body, "{{asset_url}}") do
      String.replace(comment_body, "{{asset_url}}", asset_url)
    else
      comment_body <> "\n\n" <> asset_url
    end
  end

  defp ensure_graphql_success(%{"errors" => errors}) when is_list(errors) and errors != [] do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp ensure_graphql_success(%{errors: errors}) when is_list(errors) and errors != [] do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp ensure_graphql_success(_response), do: :ok

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp success_response(payload) do
    %{
      "success" => true,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:invalid_upload_arguments) do
    %{
      "error" => %{
        "message" => "`linear_upload_issue_asset` expects an object with `issueId`, `path`, and optional `commentBody`, `contentType`, `makePublic`."
      }
    }
  end

  defp tool_error_payload(:missing_issue_id) do
    %{
      "error" => %{
        "message" => "`linear_upload_issue_asset` requires `issueId` (ticket key or internal id)."
      }
    }
  end

  defp tool_error_payload(:missing_path) do
    %{
      "error" => %{
        "message" => "`linear_upload_issue_asset` requires a non-empty `path`."
      }
    }
  end

  defp tool_error_payload(:invalid_upload_comment_body) do
    %{
      "error" => %{
        "message" => "`linear_upload_issue_asset.commentBody` must be a string when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_upload_content_type) do
    %{
      "error" => %{
        "message" => "`linear_upload_issue_asset.contentType` must be a string when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_upload_make_public) do
    %{
      "error" => %{
        "message" => "`linear_upload_issue_asset.makePublic` must be a boolean when provided."
      }
    }
  end

  defp tool_error_payload(:linear_issue_not_found) do
    %{
      "error" => %{
        "message" => "`linear_upload_issue_asset` could not resolve the target Linear issue from the provided `issueId`."
      }
    }
  end

  defp tool_error_payload(:linear_file_upload_failed) do
    %{
      "error" => %{
        "message" => "Linear did not return a usable upload slot for `linear_upload_issue_asset`."
      }
    }
  end

  defp tool_error_payload(:linear_comment_create_failed) do
    %{
      "error" => %{
        "message" => "Linear accepted the file upload, but creating the issue comment failed."
      }
    }
  end

  defp tool_error_payload({:linear_graphql_errors, errors}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL returned errors while handling the request.",
        "errors" => errors
      }
    }
  end

  defp tool_error_payload({:linear_upload_status, status}) do
    %{
      "error" => %{
        "message" => "Linear asset upload failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_upload_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear asset upload failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:upload_file_not_found, path}) do
    %{
      "error" => %{
        "message" => "Upload file not found: #{path}"
      }
    }
  end

  defp tool_error_payload({:upload_path_not_regular_file, path}) do
    %{
      "error" => %{
        "message" => "Upload path is not a regular file: #{path}"
      }
    }
  end

  defp tool_error_payload({:upload_file_too_large, size}) do
    %{
      "error" => %{
        "message" => "Upload file is too large for Linear GraphQL `Int` size handling (#{size} bytes)."
      }
    }
  end

  defp tool_error_payload({:upload_file_stat_failed, path, reason}) do
    %{
      "error" => %{
        "message" => "Unable to inspect upload file: #{path}",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:upload_file_read_failed, path, reason}) do
    %{
      "error" => %{
        "message" => "Unable to read upload file: #{path}",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
