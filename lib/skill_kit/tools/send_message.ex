defmodule SkillKit.Tools.SendMessage do
  @moduledoc """
  Tool for sending a message to a pre-bound target agent.

  The target is configured by whoever registers this tool into a tool
  scope (sub-loop, subagent, or future phonebook skill). The LLM only
  supplies the content. There is no LLM-supplied `to:` parameter — that
  is by design, so the same tool module can serve every messaging
  context with no special-casing.

  ## Context

  Expects the following keys in `%ToolExecution{}.context`:

    * `:target` — `%SkillKit.AgentRef{}` of the agent to message. The
      tool delegates to `SkillKit.send_message/2`, which casts a
      `%UserMessage{}` to that agent's mailbox.

  ## Behavior

  Returns `{:ok, "Message sent."}` on successful cast. Returns
  `{:error, "Target agent is not running."}` if the target's mailbox
  process cannot be located.
  """

  @behaviour SkillKit.Tool

  alias SkillKit.ToolExecution

  @impl SkillKit.Tool
  def definition do
    %SkillKit.Tool{
      name: "send_message",
      description: """
      Send a message to the bound target agent. The target is configured at
      tool registration time; you only supply the content. Use this when you
      want the receiving agent to wake and process what you have to say.
      """,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "content" => %{
            "type" => "string",
            "description" => "The message content to deliver to the target agent."
          }
        },
        "required" => ["content"]
      }
    }
  end

  @impl SkillKit.Tool
  def execute(%ToolExecution{input: %{"content" => content}, context: %{target: target}})
      when is_binary(content) do
    deliver(SkillKit.send_message(target, content))
  end

  def execute(%ToolExecution{input: input}) do
    {:error, "Missing required field: content (got: #{inspect(input)})"}
  end

  @impl SkillKit.Tool
  def resume(_execution, _state, _decision),
    do: {:error, "send_message does not support suspension"}

  defp deliver(:ok), do: {:ok, "Message sent."}
  defp deliver({:error, :not_found}), do: {:error, "Target agent is not running."}
end
