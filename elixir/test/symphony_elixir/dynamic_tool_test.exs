defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the supported dynamic tool contracts" do
    specs = DynamicTool.tool_specs()

    assert Enum.any?(specs, fn
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             } ->
               description =~ "Linear"

             _ ->
               false
           end)

    assert Enum.any?(specs, fn
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "commentBody" => _,
                   "contentType" => _,
                   "issueId" => _,
                   "makePublic" => _,
                   "path" => _
                 },
                 "required" => ["issueId", "path"],
                 "type" => "object"
               },
               "name" => "linear_upload_issue_asset"
             } ->
               description =~ "Upload a local file"

             _ ->
               false
           end)
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql", "linear_upload_issue_asset"]
             }
           }
  end

  test "linear_upload_issue_asset uploads a local file and creates a Linear comment" do
    test_pid = self()

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-linear-upload-tool-#{System.unique_integer([:positive])}"
      )

    file_path = Path.join(test_root, "walkthrough.mp4")
    File.mkdir_p!(test_root)
    File.write!(file_path, "video-bytes")

    on_exit(fn -> File.rm_rf(test_root) end)

    response =
      DynamicTool.execute(
        "linear_upload_issue_asset",
        %{
          "issueId" => "MEZ-153",
          "path" => file_path,
          "commentBody" => "Walkthrough video"
        },
        linear_client: fn query, variables, opts ->
          cond do
            String.contains?(query, "SymphonyResolveIssue") ->
              send(test_pid, {:resolve_issue_call, variables, opts})
              {:ok, %{"data" => %{"issue" => %{"id" => "issue-123", "identifier" => "MEZ-153"}}}}

            String.contains?(query, "SymphonyFileUpload") ->
              send(test_pid, {:file_upload_call, variables, opts})

              {:ok,
               %{
                 "data" => %{
                   "fileUpload" => %{
                     "success" => true,
                     "uploadFile" => %{
                       "uploadUrl" => "https://upload.example.test/put",
                       "assetUrl" => "https://uploads.linear.app/demo.mp4",
                       "headers" => [%{"key" => "x-test-header", "value" => "1"}]
                     }
                   }
                 }
               }}

            String.contains?(query, "SymphonyCreateComment") ->
              send(test_pid, {:comment_create_call, variables, opts})

              {:ok,
               %{
                 "data" => %{
                   "commentCreate" => %{
                     "success" => true,
                     "comment" => %{
                       "id" => "comment-1",
                       "url" => "https://linear.app/mezame-ai/comment/comment-1"
                     }
                   }
                 }
               }}

            true ->
              flunk("unexpected query: #{query}")
          end
        end,
        upload_request: fn upload_url, headers, file_info ->
          send(test_pid, {:upload_request, upload_url, headers, file_info})
          :ok
        end
      )

    assert_received {:resolve_issue_call, %{issueId: "MEZ-153"}, []}

    assert_received {:file_upload_call,
                     %{
                       contentType: "video/mp4",
                       filename: "walkthrough.mp4",
                       makePublic: false,
                       size: 11
                     }, []}

    assert_received {:upload_request, "https://upload.example.test/put", headers, %{content_type: "video/mp4", filename: "walkthrough.mp4", path: expanded_path, size: 11}}

    assert expanded_path == Path.expand(file_path)
    assert {"content-type", "video/mp4"} in headers
    assert {"x-test-header", "1"} in headers

    assert_received {:comment_create_call, %{body: "Walkthrough video\n\nhttps://uploads.linear.app/demo.mp4", issueId: "issue-123"}, []}

    assert response["success"] == true

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "assetUrl" => "https://uploads.linear.app/demo.mp4",
             "commentId" => "comment-1",
             "commentUrl" => "https://linear.app/mezame-ai/comment/comment-1",
             "contentType" => "video/mp4",
             "issueId" => "issue-123",
             "issueIdentifier" => "MEZ-153",
             "path" => Path.expand(file_path)
           }
  end

  test "linear_upload_issue_asset validates required arguments before touching Linear" do
    response =
      DynamicTool.execute(
        "linear_upload_issue_asset",
        %{"path" => "/tmp/demo.mp4"},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when upload arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_upload_issue_asset` requires `issueId` (ticket key or internal id)."
             }
           }
  end

  test "linear_upload_issue_asset formats upload transport failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-linear-upload-tool-error-#{System.unique_integer([:positive])}"
      )

    file_path = Path.join(test_root, "walkthrough.mp4")
    File.mkdir_p!(test_root)
    File.write!(file_path, "video-bytes")

    on_exit(fn -> File.rm_rf(test_root) end)

    response =
      DynamicTool.execute(
        "linear_upload_issue_asset",
        %{"issueId" => "MEZ-153", "path" => file_path},
        linear_client: fn query, _variables, _opts ->
          cond do
            String.contains?(query, "SymphonyResolveIssue") ->
              {:ok, %{"data" => %{"issue" => %{"id" => "issue-123", "identifier" => "MEZ-153"}}}}

            String.contains?(query, "SymphonyFileUpload") ->
              {:ok,
               %{
                 "data" => %{
                   "fileUpload" => %{
                     "success" => true,
                     "uploadFile" => %{
                       "uploadUrl" => "https://upload.example.test/put",
                       "assetUrl" => "https://uploads.linear.app/demo.mp4",
                       "headers" => []
                     }
                   }
                 }
               }}

            true ->
              flunk("comment creation should not be attempted after upload failure")
          end
        end,
        upload_request: fn _upload_url, _headers, _file_info ->
          {:error, {:linear_upload_request, :timeout}}
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "Linear asset upload failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert [
             %{
               "text" => missing_token_text
             }
           ] = missing_token["contentItems"]

    assert Jason.decode!(missing_token_text) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert [
             %{
               "text" => status_error_text
             }
           ] = status_error["contentItems"]

    assert Jason.decode!(status_error_text) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert [
             %{
               "text" => request_error_text
             }
           ] = request_error["contentItems"]

    assert Jason.decode!(request_error_text) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true

    assert [
             %{
               "text" => ":ok"
             }
           ] = response["contentItems"]
  end
end
