const InlineThread = {
  mounted() {
    this.reposition();
    this.focusInput();

    this._resizeHandler = () => this.reposition();
    window.addEventListener("resize", this._resizeHandler);

    // Escape clears draft and closes
    this._escHandler = (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        this.pushEvent("close_inline_thread", {});
      }
    };
    this.el.addEventListener("keydown", this._escHandler);

    // Trap tab focus within the popover
    this.el.addEventListener("keydown", (e) => {
      if (e.key !== "Tab") return;

      const focusable = this.el.querySelectorAll(
        "input, button, textarea, [tabindex]:not([tabindex='-1'])"
      );
      if (focusable.length === 0) return;

      const first = focusable[0];
      const last = focusable[focusable.length - 1];

      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    });
  },

  updated() {
    this.reposition();
  },

  focusInput() {
    const input = this.el.querySelector("input[name='message']");
    if (input) {
      requestAnimationFrame(() => input.focus());
    }
  },

  reposition() {
    const rect = this.el.getBoundingClientRect();
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    if (rect.right > vw - 16) {
      this.el.style.left = `${vw - rect.width - 16}px`;
    }
    if (rect.bottom > vh - 16) {
      this.el.style.top = `${vh - rect.height - 16}px`;
    }
  },

  destroyed() {
    window.removeEventListener("resize", this._resizeHandler);
  },
};

export default InlineThread;
