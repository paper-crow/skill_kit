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

    // Clear selection when clicking without selecting text
    this.el.addEventListener("click", () => {
      const selection = window.getSelection();
      if (!selection || selection.isCollapsed) {
        this._selectedText = null;
        this.pushEvent("clear_selection", {});
      }
    });

    // Save selection text so we can re-highlight after DOM patches
    this._selectedText = null;

    // Track text selection for inline threads
    document.addEventListener("mouseup", (e) => {
      // Ignore clicks inside the inline thread popover
      const thread = document.getElementById("inline-thread");
      if (thread && thread.contains(e.target)) return;

      const selection = window.getSelection();
      if (selection.rangeCount > 0 && !selection.isCollapsed) {
        const range = selection.getRangeAt(0);
        if (this.el.contains(range.commonAncestorContainer)) {
          const text = selection.toString();
          this._selectedText = text;
          const rect = range.getBoundingClientRect();
          this.pushEvent("text_selected", {
            text: text,
            top: rect.top,
            right: rect.right,
            width: rect.width,
          });
        }
      }
    });
  },

  updated() {
    this.highlightCode();
    this.renderMermaid();
    this.restoreSelection();
  },

  restoreSelection() {
    if (!this._selectedText) return;

    // Check if the inline thread is still open
    const thread = document.getElementById("inline-thread");
    if (!thread) {
      this._selectedText = null;
      return;
    }

    // Walk the text nodes to find and re-select the text
    const treeWalker = document.createTreeWalker(
      this.el,
      NodeFilter.SHOW_TEXT,
      null
    );

    const searchText = this._selectedText;
    let node;
    while ((node = treeWalker.nextNode())) {
      const idx = node.textContent.indexOf(searchText);
      if (idx >= 0) {
        const range = document.createRange();
        range.setStart(node, idx);
        range.setEnd(node, idx + searchText.length);
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        return;
      }
    }
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
