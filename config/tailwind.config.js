const plugin = require("tailwindcss/plugin");

module.exports = {
  content: [
    "../lib/colloq_web/**/*.{ex,heex,html}",
    "../lib/colloq/**/*.{ex,html}",
    "./js/**/*.js"
  ],
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
        surface: "#0f1420",
        bg: "#080c14",
        border: "#1a2035",
        muted: "#6b7280",
        racing: {
          blue: "#0038A8",
          sky: "#60a5fa",
          white: "#ffffff"
        }
      },
      fontFamily: {
        sans: ["DM Sans", "Segoe UI", "system-ui", "sans-serif"],
        mono: ["JetBrains Mono", "SF Mono", "monospace"]
      }
    }
  },
  plugins: [
    plugin(({ addBase }) => {
      addBase({
        "*": { scrollbarWidth: "thin", scrollbarColor: "#1a2035 #080c14" },
        "body": { backgroundColor: "#080c14", color: "#e2e5ed" }
      });
    })
  ]
};