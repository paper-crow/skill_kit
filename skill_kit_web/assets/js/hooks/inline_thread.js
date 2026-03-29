const InlineThread = {
  mounted() {
    this.reposition();
    this._resizeHandler = () => this.reposition();
    window.addEventListener("resize", this._resizeHandler);
  },
  updated() {
    this.reposition();
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
