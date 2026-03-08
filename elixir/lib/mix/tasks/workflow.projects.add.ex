defmodule Mix.Tasks.Workflow.Projects.Add do
  use Mix.Task

  @shortdoc "Add or update a tracker.projects slug/dir mapping in WORKFLOW.md"

  @moduledoc """
  Adds or updates one `tracker.projects` entry in a workflow file.

  `slug` should be the Linear project `slugId` (the suffix ID in
  `/project/<name>-<slugId>/issues`).

  Usage:

      mix workflow.projects.add --slug d0641848a5df --dir fileMaker/training
      mix workflow.projects.add --file ./WORKFLOW.md --slug symphony-4d878387ede9 --dir symphony
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [slug: :string, dir: :string, file: :string, help: :boolean],
        aliases: [h: :help, f: :file]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        slug = required_opt(opts, :slug) |> String.trim()
        dir = required_opt(opts, :dir) |> String.trim()
        workflow_path = Path.expand(opts[:file] || "WORKFLOW.md")

        if slug == "" do
          Mix.raise("Option --slug must not be empty")
        end

        if dir == "" do
          Mix.raise("Option --dir must not be empty")
        end

        action = upsert_project_mapping(workflow_path, slug, dir)

        Mix.shell().info("#{action_label(action)}: slug=#{slug} dir=#{dir} file=#{workflow_path}")
    end
  end

  defp required_opt(opts, key) do
    case opts[key] do
      nil -> Mix.raise("Missing required option --#{key}")
      value -> value
    end
  end

  defp upsert_project_mapping(workflow_path, slug, dir) do
    content =
      case File.read(workflow_path) do
        {:ok, value} -> value
        {:error, reason} -> Mix.raise("Unable to read #{workflow_path}: #{inspect(reason)}")
      end

    {front_matter_lines, prompt_lines} = split_front_matter!(content, workflow_path)
    {updated_front_matter_lines, action} = upsert_tracker_projects(front_matter_lines, slug, dir, workflow_path)

    updated_content = compose_workflow(updated_front_matter_lines, prompt_lines)

    if updated_content != content do
      File.write!(workflow_path, updated_content)
    end

    action
  end

  defp split_front_matter!(content, workflow_path) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front_matter_lines, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] ->
            {front_matter_lines, prompt_lines}

          _ ->
            Mix.raise("Invalid workflow format in #{workflow_path}: missing closing front matter delimiter")
        end

      _ ->
        Mix.raise("Invalid workflow format in #{workflow_path}: missing opening front matter delimiter")
    end
  end

  defp compose_workflow(front_matter_lines, prompt_lines) do
    content =
      ["---" | front_matter_lines]
      |> Kernel.++(["---" | prompt_lines])
      |> Enum.join("\n")

    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end

  defp upsert_tracker_projects(front_matter_lines, slug, dir, workflow_path) do
    {tracker_start, tracker_end} = tracker_block_bounds!(front_matter_lines, workflow_path)

    tracker_lines =
      front_matter_lines
      |> Enum.slice(tracker_start + 1, tracker_end - tracker_start - 1)

    {updated_tracker_lines, action} = upsert_projects_block(tracker_lines, slug, dir)

    updated_front_matter_lines =
      front_matter_lines
      |> Enum.take(tracker_start + 1)
      |> Kernel.++(updated_tracker_lines)
      |> Kernel.++(Enum.drop(front_matter_lines, tracker_end))

    {updated_front_matter_lines, action}
  end

  defp tracker_block_bounds!(front_matter_lines, workflow_path) do
    tracker_start =
      Enum.find_index(front_matter_lines, fn line ->
        indentation_level(line) == 0 and String.trim(line) == "tracker:"
      end)

    if is_nil(tracker_start) do
      Mix.raise("Invalid workflow format in #{workflow_path}: missing top-level `tracker:` section")
    end

    tracker_end =
      front_matter_lines
      |> Enum.with_index()
      |> Enum.find_value(length(front_matter_lines), fn {line, idx} ->
        if idx > tracker_start and top_level_key_line?(line), do: idx, else: nil
      end)

    {tracker_start, tracker_end}
  end

  defp top_level_key_line?(line) when is_binary(line) do
    indentation_level(line) == 0 and String.match?(line, ~r/^[^#\s][^:]*:\s*/)
  end

  defp upsert_projects_block(tracker_lines, slug, dir) do
    case find_projects_header_index(tracker_lines) do
      nil ->
        render = render_projects_lines([%{"slug" => slug, "dir" => dir}])
        insert_index = projects_insert_index(tracker_lines)
        {insert_lines(tracker_lines, insert_index, render), :added}

      projects_header_index ->
        projects_end_index = projects_block_end_index(tracker_lines, projects_header_index)

        existing_projects =
          tracker_lines
          |> Enum.slice(projects_header_index + 1, projects_end_index - projects_header_index - 1)
          |> parse_projects_block()

        {updated_projects, action} = upsert_project(existing_projects, slug, dir)
        render = render_projects_lines(updated_projects)

        {replace_lines(tracker_lines, projects_header_index, projects_end_index, render), action}
    end
  end

  defp find_projects_header_index(tracker_lines) do
    Enum.find_index(tracker_lines, fn line ->
      indentation_level(line) == 2 and String.trim(line) == "projects:"
    end)
  end

  defp projects_block_end_index(tracker_lines, projects_header_index) do
    tracker_lines
    |> Enum.with_index()
    |> Enum.find_value(length(tracker_lines), fn {line, idx} ->
      cond do
        idx <= projects_header_index ->
          nil

        String.trim(line) == "" ->
          nil

        indentation_level(line) <= 2 ->
          idx

        true ->
          nil
      end
    end)
  end

  defp parse_projects_block(lines) do
    {projects, current_project} =
      Enum.reduce(lines, {[], nil}, fn line, {projects, current_project} ->
        cond do
          String.starts_with?(line, "    - ") ->
            maybe_push_project = maybe_push_project(projects, current_project)
            kv = line |> String.trim() |> String.trim_leading("- ") |> parse_kv_line()
            {maybe_push_project, kv}

          String.starts_with?(line, "      ") and not is_nil(current_project) ->
            kv = line |> String.trim() |> parse_kv_line()
            {projects, Map.merge(current_project, kv)}

          true ->
            {projects, current_project}
        end
      end)

    projects
    |> maybe_push_project(current_project)
    |> Enum.filter(fn project ->
      case Map.get(project, "slug") do
        slug when is_binary(slug) -> String.trim(slug) != ""
        _ -> false
      end
    end)
  end

  defp maybe_push_project(projects, nil), do: projects
  defp maybe_push_project(projects, current_project), do: projects ++ [current_project]

  defp parse_kv_line(line) do
    case Regex.run(~r/^([A-Za-z0-9_]+):\s*(.*)$/, line) do
      [_, key, value] ->
        %{key => parse_scalar(value)}

      _ ->
        %{}
    end
  end

  defp parse_scalar(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed in ["", "null", "~"] ->
        nil

      String.starts_with?(trimmed, "\"") and String.ends_with?(trimmed, "\"") and byte_size(trimmed) >= 2 ->
        trimmed
        |> String.trim_leading("\"")
        |> String.trim_trailing("\"")
        |> String.replace("\\\"", "\"")
        |> String.replace("\\\\", "\\")

      String.starts_with?(trimmed, "'") and String.ends_with?(trimmed, "'") and byte_size(trimmed) >= 2 ->
        trimmed
        |> String.trim_leading("'")
        |> String.trim_trailing("'")
        |> String.replace("''", "'")

      true ->
        trimmed
    end
  end

  defp upsert_project(projects, slug, dir) do
    {updated_projects, matched?, changed?} =
      Enum.reduce(projects, {[], false, false}, fn project, {acc, matched?, changed?} ->
        case Map.get(project, "slug") do
          ^slug ->
            upsert_matching_project(acc, project, slug, dir, matched?, changed?)

          _ ->
            {acc ++ [project], matched?, changed?}
        end
      end)

    cond do
      not matched? ->
        {updated_projects ++ [%{"slug" => slug, "dir" => dir}], :added}

      changed? ->
        {updated_projects, :updated}

      true ->
        {updated_projects, :unchanged}
    end
  end

  defp upsert_matching_project(acc, _project, _slug, _dir, true, changed?) do
    {acc, true, changed?}
  end

  defp upsert_matching_project(acc, project, slug, dir, false, changed?) do
    updated_project =
      project
      |> Map.put("slug", slug)
      |> Map.put("dir", dir)

    was_changed = changed? or Map.get(project, "dir") != dir
    {acc ++ [updated_project], true, was_changed}
  end

  defp render_projects_lines(projects) do
    ["  projects:" | Enum.flat_map(projects, &render_project_lines/1)]
  end

  defp render_project_lines(project) do
    slug = Map.get(project, "slug")
    dir = Map.get(project, "dir")

    slug_line = "    - slug: " <> render_scalar(slug)

    dir_lines =
      if is_binary(dir) and String.trim(dir) != "" do
        ["      dir: " <> render_scalar(dir)]
      else
        []
      end

    extra_lines =
      project
      |> Map.drop(["slug", "dir"])
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> "      #{key}: " <> render_scalar(value) end)

    [slug_line] ++ dir_lines ++ extra_lines
  end

  defp render_scalar(nil), do: "null"
  defp render_scalar(true), do: "true"
  defp render_scalar(false), do: "false"
  defp render_scalar(value) when is_integer(value) or is_float(value), do: to_string(value)

  defp render_scalar(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"" <> escaped <> "\""
  end

  defp render_scalar(value), do: render_scalar(to_string(value))

  defp projects_insert_index(tracker_lines) do
    anchor_index =
      tracker_lines
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {line, idx}, acc ->
        if String.match?(line, ~r/^  (kind|endpoint|api_key|dirRoot|dir_root|project_slug):/) do
          idx
        else
          acc
        end
      end)

    case anchor_index do
      nil -> length(tracker_lines)
      idx -> idx + 1
    end
  end

  defp replace_lines(lines, start_idx, end_idx, replacement_lines) do
    lines
    |> Enum.take(start_idx)
    |> Kernel.++(replacement_lines)
    |> Kernel.++(Enum.drop(lines, end_idx))
  end

  defp insert_lines(lines, insert_idx, insertion_lines) do
    lines
    |> Enum.take(insert_idx)
    |> Kernel.++(insertion_lines)
    |> Kernel.++(Enum.drop(lines, insert_idx))
  end

  defp action_label(:added), do: "Added project mapping"
  defp action_label(:updated), do: "Updated project mapping"
  defp action_label(:unchanged), do: "Project mapping unchanged"

  defp indentation_level(line) when is_binary(line) do
    byte_size(line) - byte_size(String.trim_leading(line))
  end
end
