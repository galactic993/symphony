defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.Config

  @excluded_entries MapSet.new([".elixir_ls", "tmp"])

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)

    try do
      workspace = workspace_path_for_issue(issue_context)

      with :ok <- validate_workspace_path(workspace, issue_context),
           {:ok, created?} <- ensure_workspace(workspace, issue_context),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, issue_context) do
    if project_bound_workspace?(issue_context) do
      ensure_project_workspace(workspace)
    else
      ensure_issue_workspace(workspace)
    end
  end

  defp ensure_issue_workspace(workspace) do
    cond do
      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_project_workspace(workspace) do
    case File.stat(workspace) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, false}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:project_workspace_not_directory, workspace, type}}

      {:error, :enoent} ->
        File.mkdir_p!(workspace)
        {:ok, true}

      {:error, reason} ->
        {:error, {:project_workspace_unreadable, workspace, reason}}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(%{} = issue_or_identifier) do
    case project_workspace_dir(issue_or_identifier) do
      project_dir when is_binary(project_dir) and project_dir != "" ->
        :ok

      _ ->
        issue_or_identifier
        |> issue_context()
        |> Map.get(:issue_identifier)
        |> remove_issue_workspaces()
    end
  end

  def remove_issue_workspaces(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    workspace = Path.join(Config.workspace_root(), safe_id)

    remove(workspace)
    :ok
  end

  def remove_issue_workspaces(_identifier) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:before_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run")
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:after_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run")
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(%{project_dir: project_dir}) when is_binary(project_dir) do
    Path.expand(project_dir)
  end

  defp workspace_path_for_issue(%{issue_identifier: identifier}) do
    safe_id = safe_identifier(identifier)
    Path.join(Config.workspace_root(), safe_id)
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(MapSet.to_list(@excluded_entries), fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?) do
    cond do
      project_bound_workspace?(issue_context) ->
        :ok

      created? ->
        case Config.workspace_hooks()[:after_create] do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create")
        end

      true ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace) do
    case File.dir?(workspace) do
      true ->
        case Config.workspace_hooks()[:before_remove] do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.workspace_hooks()[:timeout_ms]

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, issue_context) when is_binary(workspace) and is_map(issue_context) do
    if project_bound_workspace?(issue_context) do
      validate_project_workspace_path(workspace)
    else
      validate_workspace_path(workspace)
    end
  end

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())
    root_prefix = root <> "/"

    cond do
      expanded_workspace == root ->
        {:error, {:workspace_equals_root, expanded_workspace, root}}

      String.starts_with?(expanded_workspace <> "/", root_prefix) ->
        ensure_no_symlink_components(expanded_workspace, root)

      true ->
        {:error, {:workspace_outside_root, expanded_workspace, root}}
    end
  end

  defp validate_project_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    project_workspace_root = Path.expand(Config.project_workspace_root())
    project_root_prefix = project_workspace_root <> "/"

    if String.starts_with?(expanded_workspace <> "/", project_root_prefix) do
      case File.stat(expanded_workspace) do
        {:ok, %File.Stat{type: :directory}} ->
          :ok

        {:ok, %File.Stat{type: type}} ->
          {:error, {:project_workspace_not_directory, expanded_workspace, type}}

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          {:error, {:project_workspace_unreadable, expanded_workspace, reason}}
      end
    else
      {:error, {:project_workspace_outside_root, expanded_workspace, project_workspace_root}}
    end
  end

  defp ensure_no_symlink_components(workspace, root) do
    workspace
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current_path ->
      next_path = Path.join(current_path, segment)

      case File.lstat(next_path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:workspace_symlink_escape, next_path, root}}}

        {:ok, _stat} ->
          {:cont, next_path}

        {:error, :enoent} ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, {:workspace_path_unreadable, next_path, reason}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _reason} = error -> error
      _final_path -> :ok
    end
  end

  defp issue_context(%{} = issue) do
    project_slug = issue_project_slug(issue)
    project_name = issue_project_name(issue)

    %{
      issue_id: issue_field(issue, :id),
      issue_identifier: issue_field(issue, :identifier) || "issue",
      project_slug: project_slug,
      project_name: project_name,
      project_dir: issue_project_dir(issue)
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      project_slug: nil,
      project_name: nil,
      project_dir: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      project_slug: nil,
      project_name: nil,
      project_dir: nil
    }
  end

  defp issue_field(issue, key) when is_map(issue) and is_atom(key) do
    Map.get(issue, key) || Map.get(issue, Atom.to_string(key))
  end

  defp issue_project_slug(issue) do
    issue
    |> issue_field(:project_slug)
    |> normalize_project_slug()
  end

  defp issue_project_name(issue) do
    issue
    |> issue_field(:project_name)
    |> normalize_project_name()
  end

  defp issue_project_dir(issue) do
    issue
    |> issue_field(:project_dir)
    |> normalize_project_dir()
    |> case do
      nil ->
        slug_mapped_dir =
          issue
          |> issue_project_slug()
          |> Config.linear_project_dir()

        case slug_mapped_dir do
          project_dir when is_binary(project_dir) ->
            project_dir

          _ ->
            issue
            |> issue_project_name()
            |> Config.project_workspace_dir()
        end

      project_dir ->
        project_dir
    end
  end

  defp normalize_project_slug(project_slug) when is_binary(project_slug) do
    case String.trim(project_slug) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_project_slug(_project_slug), do: nil

  defp normalize_project_name(project_name) when is_binary(project_name) do
    case String.trim(project_name) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_project_name(_project_name), do: nil

  defp normalize_project_dir(project_dir) when is_binary(project_dir) do
    case String.trim(project_dir) do
      "" -> nil
      normalized -> Path.expand(normalized)
    end
  end

  defp normalize_project_dir(_project_dir), do: nil

  defp project_workspace_dir(issue_or_identifier) when is_map(issue_or_identifier) do
    issue_or_identifier
    |> issue_context()
    |> Map.get(:project_dir)
  end

  defp project_bound_workspace?(%{project_dir: project_dir}) when is_binary(project_dir) do
    String.trim(project_dir) != ""
  end

  defp project_bound_workspace?(_issue_context), do: false

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier} = issue_context) do
    project_slug = Map.get(issue_context, :project_slug)
    project_name = Map.get(issue_context, :project_name)

    project_context =
      [
        if(is_binary(project_slug) and project_slug != "", do: "project_slug=#{project_slug}"),
        if(is_binary(project_name) and project_name != "", do: "project_name=#{project_name}")
      ]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> ""
        values -> " " <> Enum.join(values, " ")
      end

    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}#{project_context}"
  end
end
