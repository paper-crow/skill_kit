defmodule SkillKit.Scope do
  @moduledoc false

  def valid?(_), do: false
  def validate(_), do: {:error, :stub}
  def covers?(_, _), do: false
  def any_covers?(_, _), do: false
end
