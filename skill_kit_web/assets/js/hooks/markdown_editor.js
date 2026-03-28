const MarkdownEditor = {
  mounted() {
    this.highlightCode();
    this.renderMermaid();

    // Track text selection for inline threads (Plan 3)
    document.addEventListener("mouseup", () => {
      const selection = window.getSelection();
      if (selection.rangeCount > 0 && !selection.isCollapsed) {
        const range = selection.getRangeAt(0);
        if (this.el.contains(range.commonAncestorContainer)) {
          const text = selection.toString();
          const rect = range.getBoundingClientRect();
          this.pushEvent("text_selected", {
            text: text,
            top: rect.top,
            left: rect.left,
            width: rect.width,
          });
        }
      }
    });
  },

  updated() {
    this.highlightCode();
    this.renderMermaid();
  },

  highlightCode() {
    if (typeof hljs !== "undefined") {
      this.el.querySelectorAll("pre code").forEach((block) => {
        if (!block.classList.contains("language-mermaid")) {
          hljs.highlightElement(block);
        }
      });
    }
  },

  async renderMermaid() {
    if (typeof window.mermaid === "undefined") return;

    const blocks = this.el.querySelectorAll("code.language-mermaid");
    for (const block of blocks) {
      const pre = block.parentElement;
      if (pre.dataset.mermaidRendered) continue;

      const source = block.textContent;
      const id = `mermaid-${Date.now()}-${Math.random().toString(36).slice(2)}`;

      try {
        const { svg } = await window.mermaid.render(id, source);
        const wrapper = document.createElement("div");
        wrapper.className = "mermaid-diagram my-4 flex justify-center";
        wrapper.innerHTML = svg;
        pre.replaceWith(wrapper);
      } catch (e) {
        // Leave the code block as-is if mermaid can't parse it
        pre.dataset.mermaidRendered = "error";
      }
    }
  },
};

export default MarkdownEditor;
