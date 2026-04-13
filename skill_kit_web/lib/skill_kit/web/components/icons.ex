defmodule SkillKit.Web.Components.Icons do
  @moduledoc """
  Icon component using Heroicons.

  Icons are embedded at compile time as inline SVGs from the `heroicons`
  dependency. This avoids needing a Tailwind plugin for mask-image CSS.

  ## Usage

      <.icon name="hero-arrow-right" class="w-4 h-4" />
      <.icon name="hero-arrow-up-solid" class="w-4 h-4" />
      <.icon name="hero-arrow-up-mini" class="w-5 h-5" />

  ## Styles

    * Outline (24x24) — default: `hero-arrow-right`
    * Solid (24x24): `hero-arrow-right-solid`
    * Mini (20x20): `hero-arrow-right-mini`
    * Micro (16x16): `hero-arrow-right-micro`
  """

  use Phoenix.Component

  @icons_dir Path.expand("../../../../deps/heroicons/optimized", __DIR__)

  attr :name, :string, required: true
  attr :class, :string, default: nil
  attr :rest, :global

  def icon(%{name: "hero-" <> rest} = assigns) do
    {style, icon_name} = parse_icon_name(rest)
    svg = read_icon!(style, icon_name)

    assigns =
      assigns
      |> assign(:svg, inject_class(svg, assigns[:class]))

    ~H"""
    {Phoenix.HTML.raw(@svg)}
    """
  end

  defp parse_icon_name(name) do
    cond do
      String.ends_with?(name, "-solid") ->
        {"24/solid", String.replace_suffix(name, "-solid", "")}

      String.ends_with?(name, "-mini") ->
        {"20/solid", String.replace_suffix(name, "-mini", "")}

      String.ends_with?(name, "-micro") ->
        {"16/solid", String.replace_suffix(name, "-micro", "")}

      true ->
        {"24/outline", name}
    end
  end

  defp read_icon!(style, name) do
    path = Path.join([@icons_dir, style, "#{name}.svg"])

    case File.read(path) do
      {:ok, svg} -> svg
      {:error, _} -> raise "Heroicon not found: #{style}/#{name}.svg"
    end
  end

  defp inject_class(svg, nil), do: svg
  defp inject_class(svg, ""), do: svg

  defp inject_class(svg, class) do
    String.replace(svg, "<svg", ~s(<svg class="#{class}"), global: false)
  end
end
