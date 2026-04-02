const OnboardingInput = {
  mounted() {
    this.focusAfterAnimation();
  },
  updated() {
    this.focusAfterAnimation();
  },
  focusAfterAnimation() {
    // Wait for CSS animations to complete before focusing
    const delay = parseInt(this.el.dataset.focusDelay || "400", 10);
    setTimeout(() => {
      this.el.focus();
    }, delay);
  },
};

export default OnboardingInput;
