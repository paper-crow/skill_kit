// skill_kit_web/assets/js/hooks/theme.js
const Theme = {
  mounted() {
    this.el.addEventListener("click", () => {
      const root = document.getElementById("skill-kit-root");
      const isDark = root.classList.contains("dark");

      if (isDark) {
        root.classList.remove("dark");
        localStorage.setItem("skill_kit_theme", "light");
      } else {
        root.classList.add("dark");
        localStorage.setItem("skill_kit_theme", "dark");
      }
    });
  },
};

export default Theme;
