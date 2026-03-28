const MarkdownEditor = {
  mounted() {
    this.highlightCode();
    this.renderMermaid();

    // Scroll to top when switching documents
    this.handleEvent("scroll_to_top", () => {
      this.el.closest(".overflow-y-auto")?.scrollTo({ top: 0 });
    });

    // Listen for scroll-to-heading events from the server
    this.handleEvent("scroll_to_heading", ({ heading }) => {
      // Find the h2 element whose text matches (h2 = ## headings in our rendering)
      const headings = this.el.querySelectorAll("h2, h3, h4");
      for (const el of headings) {
        if (el.textContent.trim() === heading) {
          el.scrollIntoView({ behavior: "smooth", block: "start" });
          break;
        }
      }
    });

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
        pre.dataset.mermaidRendered = "error";

        // Show a styled error inline instead of the mermaid bomb
        const errorMsg = e.message || e.toString();
        const wrapper = document.createElement("div");
        wrapper.className =
          "my-4 rounded-lg border border-red-500/20 bg-red-500/5 p-4 text-sm";
        wrapper.innerHTML =
          `<div class="text-red-400 font-medium mb-1">Mermaid syntax error</div>` +
          `<pre class="text-red-300/60 text-xs whitespace-pre-wrap">${errorMsg.replace(/</g, "&lt;")}</pre>`;
        pre.replaceWith(wrapper);

        // Send error back to the agent so it can fix the diagram
        this.pushEvent("mermaid_error", {
          error: errorMsg,
          source: source,
          path: this.el.dataset.path,
        });
      }
    }
  },
};

export default MarkdownEditor;
