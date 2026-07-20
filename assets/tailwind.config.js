const plugin = require("tailwindcss/plugin");

module.exports = {
  content: [
    "../lib/colloq_web/**/*.{ex,heex,html}",
    "../lib/colloq/**/*.{ex,html}",
    "./js/**/*.js"
  ],
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        brand: {
          50: "#eff6ff",
          100: "#dbeafe",
          200: "#bfdbfe",
          300: "#93c5fd",
          400: "#60a5fa",
          500: "#3b82f6",
          600: "#2563eb",
          700: "#1d4ed8",
          800: "#1e40af",
          900: "#1e3a8a"
        },
        surface: "var(--surface)",
        "surface-alt": "var(--surface-alt)",
        bg: "var(--bg)",
        border: "var(--border)",
        "border-hover": "var(--border-hover)",
        muted: "var(--text-muted)",
        accent: "var(--accent)",
        "accent-hover": "var(--accent-hover)",
        "accent-muted": "var(--accent-muted)",
        "accent-soft": "var(--accent-soft)",
        "accent-border": "var(--accent-border)",
        danger: "var(--danger)",
        "danger-soft": "var(--danger-soft)",
        "danger-border": "var(--danger-border)",
        success: "var(--success)",
        "success-soft": "var(--success-soft)",
        warning: "var(--warning)",
        "warning-soft": "var(--warning-soft)",
        orange: "var(--orange)",
        "orange-soft": "var(--orange-soft)",
        racing: {
          blue: "#0038A8",
          celeste: "#5CB8E6",
          sky: "#60a5fa",
          white: "#ffffff"
        }
      },
      fontFamily: {
        sans: ["Inter", "Segoe UI", "system-ui", "sans-serif", "Noto Color Emoji"],
        mono: ["JetBrains Mono", "SF Mono", "monospace", "Noto Color Emoji"]
      },
      textColor: {
        heading: "var(--text-heading)",
        body: "var(--text)",
        muted: "var(--text-muted)",
        accent: "var(--accent)"
      },
      borderColor: {
        DEFAULT: "var(--border)"
      }
    }
  },
  plugins: [
    plugin(({ addBase }) => {
      addBase({
        "*": { scrollbarWidth: "thin", scrollbarColor: "var(--scrollbar-thumb) var(--scrollbar-track)" },
        "body": { backgroundColor: "var(--bg)", color: "var(--text)", colorScheme: "var(--color-scheme)" }
      });
    })
  ]
};
