// skill_kit_web/assets/js/hooks/theme.js
const Theme = {
  mounted() {
    this.el.addEventListener("click", () => {
      const root = document.getElementById("skill-kit-root");
      const isDark = root.classList.contains("dark");
      const darkSheet = document.getElementById("hljs-dark");
      const lightSheet = document.getElementById("hljs-light");

      if (isDark) {
        root.classList.remove("dark");
        localStorage.setItem("skill_kit_theme", "light");
        if (darkSheet) darkSheet.setAttribute("disabled", "");
        if (lightSheet) lightSheet.removeAttribute("disabled");
      } else {
        root.classList.add("dark");
        localStorage.setItem("skill_kit_theme", "dark");
        if (lightSheet) lightSheet.setAttribute("disabled", "");
        if (darkSheet) darkSheet.removeAttribute("disabled");
      }
    });
  },
};

export default Theme;
