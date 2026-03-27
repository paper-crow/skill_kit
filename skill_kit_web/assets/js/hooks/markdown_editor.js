// skill_kit_web/assets/js/hooks/markdown_editor.js
const MarkdownEditor = {
  mounted() {
    this.el.addEventListener("input", () => {
      const content = this.el.innerText;
      this.pushEvent("editor_change", {
        path: this.el.dataset.path,
        content: content,
      });
    });

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
};

export default MarkdownEditor;
