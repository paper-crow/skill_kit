defmodule SkillKit.Shell do
  @moduledoc """
  Shell handler kit — provides bash command execution.

  Registered through `skills:` like any other kit:

      SkillKit.start_agent(
        skills: [
          {SkillKit.Shell, cwd: File.cwd!()},
          {SkillKit.Backend.Filesystem, dir: ".skills"}
        ]
      )

  ## Options

    * `:cwd` — working directory for commands (default: `File.cwd!()`)
    * `:env` — list of `{key, value}` environment variables
  """

  use SkillKit.Kit, name: "shell"

  alias SkillKit.Pipeline

  @impl SkillKit.Backend
  def load_kits(config) do
    {:ok, [kit]} = super(config)
    metadata = Map.merge(kit.metadata, config_to_metadata(config))
    {:ok, [%{kit | metadata: metadata}]}
  end

  @impl SkillKit.Handler.Behaviour
  def execute(%Pipeline{input: %{"command" => command}, context: context}) do
    opts = [:binary, :exit_status, :stderr_to_stdout] ++ port_opts(context)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("sh")},
        [args: ["-c", command]] ++ opts
      )

    collect(port, [])
  end

  @impl SkillKit.Handler.Behaviour
  def tool_definition do
    %SkillKit.Handler.ToolDefinition{
      name: "bash",
      description:
        "Execute a shell command. Use for running scripts, reading/writing files, " <>
          "fetching URLs (curl), git operations, and any system interaction. " <>
          "The working directory defaults to the current process working directory.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "The shell command to execute"
          }
        },
        "required" => ["command"]
      }
    }
  end

  @impl SkillKit.Handler.Behaviour
  def resume(%Pipeline{} = exec, _state, :approved), do: execute(exec)
  def resume(_exec, _state, {:denied, reason}), do: {:error, {:denied, reason}}

  defp config_to_metadata(config) do
    %{}
    |> maybe_put(:cwd, Keyword.get(config, :cwd))
    |> maybe_put(:env, Keyword.get(config, :env))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp port_opts(context) do
    []
    |> maybe_add_cd(context)
    |> maybe_add_env(context)
  end

  defp maybe_add_cd(opts, %{cwd: cwd}) when is_binary(cwd), do: [{:cd, cwd} | opts]
  defp maybe_add_cd(opts, _context), do: [{:cd, File.cwd!()} | opts]

  defp maybe_add_env(opts, %{env: env}) when is_list(env) do
    merged =
      System.get_env()
      |> Map.merge(Map.new(env))
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    [{:env, merged} | opts]
  end

  defp maybe_add_env(opts, _context), do: opts

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, [acc | data])
      {^port, {:exit_status, 0}} -> {:ok, IO.iodata_to_binary(acc)}
      {^port, {:exit_status, code}} -> {:error, {IO.iodata_to_binary(acc), code}}
    end
  end
end
