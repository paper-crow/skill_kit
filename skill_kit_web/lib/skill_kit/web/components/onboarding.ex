defmodule SkillKit.Web.Components.Onboarding do
  @moduledoc """
  Function components for the onboarding Typeform-style UI.
  """

  use Phoenix.Component

  import SkillKit.Web.Components.Icons

  attr(:error, :string, required: true)

  def error_state(assigns) do
    ~H"""
    <div class="font-heading text-2xl text-editor-text leading-snug mb-2">
      {@error}
    </div>
    """
  end

  attr(:summary, :string, default: nil)

  def ready_state(assigns) do
    ~H"""
    <div class="animate-onboarding-fade-in">
      <h2 class="font-heading text-[28px] text-editor-text leading-snug mb-4">
        Your project brief is ready
      </h2>
      <p :if={@summary} class="text-[15px] text-editor-text-muted leading-relaxed mb-10">
        {@summary}
      </p>
      <button
        phx-click="get_started"
        class="inline-flex items-center gap-2 px-6 py-3
               bg-editor-accent text-white rounded-xl text-[15px]
               hover:opacity-90 transition-opacity"
      >
        Get started <.icon name="hero-arrow-right-mini" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  attr(:text, :string, required: true)

  def waiting_state(assigns) do
    ~H"""
    <div class="animate-onboarding-fade-in">
      <div class="flex items-center gap-3">
        <div class="flex gap-1">
          <span class="w-1.5 h-1.5 rounded-full bg-editor-accent-muted animate-pulse" />
          <span class="w-1.5 h-1.5 rounded-full bg-editor-accent-muted animate-pulse [animation-delay:150ms]" />
          <span class="w-1.5 h-1.5 rounded-full bg-editor-accent-muted animate-pulse [animation-delay:300ms]" />
        </div>
        <span class="text-[15px] text-editor-text-faint">{@text}</span>
      </div>
    </div>
    """
  end

  attr(:question, :string, required: true)
  attr(:subtext, :string, default: nil)
  attr(:placeholder, :string, default: "")
  attr(:animate, :boolean, default: false)
  attr(:question_key, :integer, required: true)

  def question_state(assigns) do
    delay_base = word_count(assigns.question) * 40

    assigns =
      assigns
      |> assign(:subtext_delay, "#{delay_base + 100}ms")
      |> assign(:input_delay, "#{delay_base + 200}ms")

    ~H"""
    <div>
      <h1 class="font-heading text-[28px] text-editor-text leading-snug mb-2">
        <.animated_words :if={@animate} text={@question} key={@question_key} />
        <span :if={!@animate}>{@question}</span>
      </h1>
      <p
        :if={@subtext}
        data-animate={"#{@animate}"}
        class="text-[15px] text-editor-text-faint leading-relaxed mb-9
               data-[animate=true]:animate-onboarding-fade-in data-[animate=true]:opacity-0"
        style={"animation-delay: #{@subtext_delay}"}
      >
        {@subtext}
      </p>
      <div
        data-animate={"#{@animate}"}
        class="mt-9 data-[animate=true]:animate-onboarding-fade-in data-[animate=true]:opacity-0"
        style={"animation-delay: #{@input_delay}"}
      >
        <form phx-submit="submit_answer" class="relative">
          <textarea
            id={"onboarding-input-#{@question_key}"}
            name="answer"
            rows="3"
            placeholder={@placeholder}
            autocomplete="off"
            phx-hook="OnboardingInput"
            class="w-full bg-white dark:bg-editor-bg-alt border border-editor-border rounded-xl
                   px-5 py-4 pr-16 text-[15px] text-editor-text placeholder-editor-text-faint
                   focus:outline-none focus:border-editor-accent-muted
                   resize-none transition-colors"
          />
          <button
            type="submit"
            class="absolute right-3 bottom-3
                   w-9 h-9 rounded-full bg-editor-accent text-white
                   flex items-center justify-center
                   hover:opacity-90 transition-opacity"
          >
            <.icon name="hero-arrow-up-mini" class="w-4 h-4" />
          </button>
        </form>
      </div>
    </div>
    """
  end

  attr(:text, :string, required: true)
  attr(:key, :integer, required: true)

  def animated_words(assigns) do
    assigns = assign(assigns, :words, String.split(assigns.text))

    ~H"""
    <span
      :for={{word, idx} <- Enum.with_index(@words)}
      class="inline-block animate-onboarding-word-reveal opacity-0"
      style={"animation-delay: #{idx * 40}ms"}
    >
      {word}<span :if={idx < length(@words) - 1}>&nbsp;</span>
    </span>
    """
  end

  defp word_count(text), do: text |> String.split() |> length()
end
