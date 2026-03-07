defmodule Mix.Tasks.Workflow.Projects.AddTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Workflow.Projects.Add

  setup do
    Mix.Task.reenable("workflow.projects.add")
    :ok
  end

  test "adds tracker.projects when missing" do
    in_temp_project(fn ->
      write_workflow_file!(
        "WORKFLOW.md",
        """
        ---
        tracker:
          kind: linear
          project_slug: "current-project"
        polling:
          interval_ms: 5000
        ---
        Prompt body
        """
      )

      output =
        capture_io(fn ->
          assert :ok = Add.run(["--slug", "d0641848a5df", "--dir", "fileMaker/training"])
        end)

      assert output =~ "Added project mapping"
      config = read_workflow_config!("WORKFLOW.md")

      assert get_in(config, ["tracker", "projects"]) == [
               %{"slug" => "d0641848a5df", "dir" => "fileMaker/training"}
             ]
    end)
  end

  test "updates dir when slug already exists without duplicating entries" do
    in_temp_project(fn ->
      write_workflow_file!(
        "WORKFLOW.md",
        """
        ---
        tracker:
          kind: linear
          projects:
            - slug: "d0641848a5df"
              dir: "old/path"
            - slug: "symphony-4d878387ede9"
              dir: "symphony"
        ---
        Prompt body
        """
      )

      output =
        capture_io(fn ->
          assert :ok = Add.run(["--slug", "d0641848a5df", "--dir", "fileMaker/training"])
        end)

      assert output =~ "Updated project mapping"

      projects =
        "WORKFLOW.md"
        |> read_workflow_config!()
        |> get_in(["tracker", "projects"])

      assert Enum.count(projects, &(&1["slug"] == "d0641848a5df")) == 1

      assert Enum.find(projects, &(&1["slug"] == "d0641848a5df"))["dir"] ==
               "fileMaker/training"
    end)
  end

  test "appends new project to existing list" do
    in_temp_project(fn ->
      write_workflow_file!(
        "WORKFLOW.md",
        """
        ---
        tracker:
          kind: linear
          projects:
            - slug: "symphony-4d878387ede9"
              dir: "symphony"
        ---
        Prompt body
        """
      )

      output =
        capture_io(fn ->
          assert :ok = Add.run(["--slug", "d0641848a5df", "--dir", "fileMaker/training"])
        end)

      assert output =~ "Added project mapping"

      projects =
        "WORKFLOW.md"
        |> read_workflow_config!()
        |> get_in(["tracker", "projects"])

      assert Enum.map(projects, & &1["slug"]) == ["symphony-4d878387ede9", "d0641848a5df"]

      assert Enum.find(projects, &(&1["slug"] == "d0641848a5df"))["dir"] ==
               "fileMaker/training"
    end)
  end

  test "raises when tracker section is missing" do
    in_temp_project(fn ->
      write_workflow_file!(
        "WORKFLOW.md",
        """
        ---
        polling:
          interval_ms: 5000
        ---
        Prompt body
        """
      )

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/missing top-level `tracker:` section/, fn ->
            Add.run(["--slug", "d0641848a5df", "--dir", "fileMaker/training"])
          end
        end)

      assert error_output =~ "missing top-level `tracker:` section"
    end)
  end

  defp in_temp_project(fun) do
    root =
      Path.join(
        System.tmp_dir!(),
        "workflow-projects-add-task-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    original_cwd = File.cwd!()
    File.rm_rf!(root)
    File.mkdir_p!(root)

    try do
      File.cd!(root, fun)
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  defp write_workflow_file!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, String.trim_leading(content))
  end

  defp read_workflow_config!(path) do
    content = File.read!(path)
    [_, front_matter, _prompt] = Regex.run(~r/\A---\n(.*?)\n---\n(.*)\z/s, content)
    YamlElixir.read_from_string!(front_matter)
  end
end
