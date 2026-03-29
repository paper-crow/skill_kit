defmodule SkillKit.Web.Components.DiffBlock do
  use Phoenix.Component

  attr(:diff, :map, default: nil)

  def diff_block(%{diff: nil} = assigns), do: ~H""

  def diff_block(assigns) do
    ~H"""
    <div class="rounded-lg border border-editor-border overflow-hidden my-3">
      <div class="flex items-center justify-between px-3 py-2 bg-editor-bg-alt border-b border-editor-border">
        <span class="text-sm text-editor-text-faint">
          Change proposed to <span class="font-medium text-editor-text-muted">{@diff.path}</span>
        </span>
        <div class="flex gap-2">
          <button
            phx-click="reject_diff"
            class="text-xs px-2 py-1 rounded text-red-400 hover:bg-red-500/10 transition-colors"
          >
            Reject
          </button>
          <button
            phx-click="accept_diff"
            class="text-xs px-2 py-1 rounded bg-editor-accent text-white hover:opacity-90 transition-opacity"
          >
            Accept
          </button>
        </div>
      </div>
      <div class="grid grid-cols-2 divide-x divide-editor-border">
        <div class="p-3">
          <div class="text-xs text-red-400/60 font-medium mb-2 uppercase tracking-wide">Previous</div>
          <pre class="text-xs text-editor-text-faint whitespace-pre-wrap font-mono leading-relaxed">{@diff.old_content}</pre>
        </div>
        <div class="p-3">
          <div class="text-xs text-green-400/60 font-medium mb-2 uppercase tracking-wide">
            Proposed
          </div>
          <pre class="text-xs text-editor-text-muted whitespace-pre-wrap font-mono leading-relaxed">{@diff.new_content}</pre>
        </div>
      </div>
    </div>
    """
  end
end
