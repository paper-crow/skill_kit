defmodule SkillKit.Tools.Shell do
  @moduledoc """
  Shell tool — provides bash command execution in a hermetic child
  environment.

  Registered through `skills:` like any other kit:

      SkillKit.start_agent(
        skills: [
          {SkillKit.Tools.Shell, cwd: File.cwd!(), env: %{"LANG" => "en_US.UTF-8"}},
          {SkillKit.Kit.Local, dir: ".skills"}
        ]
      )

  ## Options

    * `:cwd` — working directory for commands (default: `File.cwd!()`)
    * `:env` — map of non-secret ambient env vars to inject into the child
      process (`%{"LANG" => "en_US.UTF-8"}`). NOT a secret channel — use
      `SkillKit.CredentialProvider` for secrets.

  ## Hermetic execution

  Commands run under `/usr/bin/env -i`, which starts the child with an
  empty environment. SkillKit then sets exactly what the child should
  see, in this order:

    1. Hardcoded base: `PATH=/usr/bin:/bin` and `HOME` copied from BEAM.
    2. The tool-config `:env` map (non-secret ambient vars).
    3. Credentials returned by the configured `SkillKit.CredentialProvider`.
       Credentials win on key collision.

  BEAM's own environment (including `ANTHROPIC_API_KEY` and anything else
  the host app has set) does not leak into the child.
  """

  use SkillKit.Kit, name: "shell"

  alias SkillKit.ToolExecution

  @env_executable "/usr/bin/env"

  @impl SkillKit.Kit.Provider
  def load_kits(config) do
    {:ok, [kit]} = super(config)
    metadata = Map.merge(kit.metadata, config_to_metadata(config))
    {:ok, [%{kit | metadata: metadata}]}
  end

  @impl SkillKit.Tool
  def execute(%ToolExecution{input: %{"command" => command}, context: context}) do
    env_args = build_env_args(context)
    port_opts = [:binary, :exit_status, :stderr_to_stdout] ++ cwd_opt(context)

    port =
      Port.open(
        {:spawn_executable, @env_executable},
        [args: env_args ++ ["sh", "-c", command]] ++ port_opts
      )

    collect(port, [])
  end

  @impl SkillKit.Tool
  def definition do
    %SkillKit.Tool{
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

  @impl SkillKit.Tool
  def resume(%ToolExecution{} = exec, _state, :approved), do: execute(exec)
  def resume(_exec, _state, {:denied, reason}), do: {:error, {:denied, reason}}

  defp config_to_metadata(config) do
    %{tool: __MODULE__}
    |> maybe_put(:cwd, Keyword.get(config, :cwd))
    |> maybe_put(:env, Keyword.get(config, :env))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Builds the ["-i", "KEY=VAL", ...] arg list passed to /usr/bin/env.
  defp build_env_args(context) do
    base = %{
      "PATH" => "/usr/bin:/bin",
      "HOME" => System.get_env("HOME") || ""
    }

    config_env = Map.get(context, :env, %{})
    creds = fetch_credentials(context)

    env_map =
      base
      |> Map.merge(config_env)
      |> Map.merge(creds)

    ["-i"] ++ Enum.map(env_map, &format_env_pair/1)
  end

  defp fetch_credentials(%{agent: agent}) do
    provider = Application.get_env(:skill_kit, :credential_provider, SkillKit.CredentialProvider)

    provider
    |> apply(:list, [__MODULE__, agent])
    |> Enum.reduce(%{}, &maybe_put_credential(&1, &2, provider, agent))
  end

  defp fetch_credentials(_context), do: %{}

  defp maybe_put_credential(key, acc, provider, agent) do
    case apply(provider, :fetch, [__MODULE__, agent, key]) do
      {:ok, value} when is_binary(value) -> Map.put(acc, key, value)
      {:ok, nil} -> acc
      :error -> acc
    end
  end

  defp format_env_pair({key, value}), do: "#{key}=#{value}"

  defp cwd_opt(%{cwd: cwd}) when is_binary(cwd), do: [{:cd, cwd}]
  defp cwd_opt(_context), do: [{:cd, File.cwd!()}]

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, [acc | data])
      {^port, {:exit_status, 0}} -> {:ok, IO.iodata_to_binary(acc)}
      {^port, {:exit_status, code}} -> {:error, {IO.iodata_to_binary(acc), code}}
    end
  end
end
