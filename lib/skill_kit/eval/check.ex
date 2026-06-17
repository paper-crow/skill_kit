defmodule SkillKit.Eval.Check do
  @moduledoc """
  A single pass/fail assertion produced while scoring an eval.

  A `SkillKit.Eval.Result` is the collection of checks for one eval run; the
  run passes only when every check passes. `:detail` carries a human-readable
  explanation, surfaced in ExUnit failure output. `:warning` carries a
  non-fatal note on a *passing* check — a minor, non-critical deviation the
  judge flagged but did not fail on.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          passed: boolean(),
          detail: String.t() | nil,
          warning: String.t() | nil
        }

  @enforce_keys [:name, :passed]
  defstruct [:name, :passed, :detail, :warning]

  @doc "Builds a check with an explicit pass/fail and optional detail."
  @spec new(String.t(), boolean(), String.t() | nil) :: t()
  def new(name, passed, detail \\ nil) do
    %__MODULE__{name: name, passed: passed, detail: detail}
  end

  @doc "Builds a passing check, optionally carrying a non-fatal warning note."
  @spec pass(String.t(), String.t() | nil, String.t() | nil) :: t()
  def pass(name, detail \\ nil, warning \\ nil) do
    %__MODULE__{name: name, passed: true, detail: detail, warning: warning}
  end

  @doc "Builds a failing check."
  @spec fail(String.t(), String.t()) :: t()
  def fail(name, detail), do: new(name, false, detail)
end
