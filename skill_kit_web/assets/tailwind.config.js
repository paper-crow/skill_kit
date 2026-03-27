const plugin = require("tailwindcss/plugin")

module.exports = {
  content: [
    "../lib/**/*.ex",
    "../lib/**/*.heex",
  ],
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        editor: {
          bg: "var(--editor-bg)",
          "bg-alt": "var(--editor-bg-alt)",
          text: "var(--editor-text)",
          "text-muted": "var(--editor-text-muted)",
          "text-faint": "var(--editor-text-faint)",
          accent: "var(--editor-accent)",
          "accent-muted": "var(--editor-accent-muted)",
          "accent-faint": "var(--editor-accent-faint)",
          border: "var(--editor-border)",
          divider: "var(--editor-divider)",
        },
      },
      fontFamily: {
        heading: ["Georgia", "'Times New Roman'", "serif"],
        mono: ["'JetBrains Mono'", "'SF Mono'", "ui-monospace", "monospace"],
      },
      fontSize: {
        "editor-body": ["14px", { lineHeight: "1.9" }],
        "editor-heading": ["24px", { lineHeight: "1.3" }],
        "editor-label": ["11px", { lineHeight: "1.5", letterSpacing: "0.125em" }],
      },
      maxWidth: {
        editor: "620px",
      },
      spacing: {
        "section": "24px",
      },
    },
  },
  plugins: [
    plugin(function({ addBase }) {
      addBase({
        ":root": {
          "--editor-bg": "#f8f8f6",
          "--editor-bg-alt": "#f0eeea",
          "--editor-text": "#1a1a1a",
          "--editor-text-muted": "rgba(0, 0, 0, 0.6)",
          "--editor-text-faint": "rgba(0, 0, 0, 0.35)",
          "--editor-accent": "rgba(70, 90, 140, 0.8)",
          "--editor-accent-muted": "rgba(70, 90, 140, 0.6)",
          "--editor-accent-faint": "rgba(70, 90, 140, 0.08)",
          "--editor-border": "rgba(0, 0, 0, 0.06)",
          "--editor-divider": "rgba(0, 0, 0, 0.05)",
        },
        ".dark": {
          "--editor-bg": "#0d0d14",
          "--editor-bg-alt": "#0a0a12",
          "--editor-text": "rgba(255, 255, 255, 0.88)",
          "--editor-text-muted": "rgba(255, 255, 255, 0.55)",
          "--editor-text-faint": "rgba(255, 255, 255, 0.35)",
          "--editor-accent": "rgba(140, 160, 210, 0.8)",
          "--editor-accent-muted": "rgba(140, 160, 210, 0.6)",
          "--editor-accent-faint": "rgba(140, 160, 210, 0.08)",
          "--editor-border": "rgba(255, 255, 255, 0.06)",
          "--editor-divider": "rgba(255, 255, 255, 0.04)",
        },
      })
    }),
  ],
}
