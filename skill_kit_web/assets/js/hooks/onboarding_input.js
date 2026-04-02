const OnboardingInput = {
  mounted() {
    this.focusAfterAnimation();
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        this.el.closest("form").dispatchEvent(
          new Event("submit", { bubbles: true, cancelable: true })
        );
      }
    });
  },
  updated() {
    this.focusAfterAnimation();
  },
  focusAfterAnimation() {
    const delay = parseInt(this.el.dataset.focusDelay || "400", 10);
    setTimeout(() => {
      this.el.focus();
    }, delay);
  },
};

export default OnboardingInput;
