import type { Config } from "tailwindcss";

/**
 * BoutiqueOS design tokens.
 * Warm neutral, print-like: hairlines instead of shadows, small radii, one accent
 * (aubergine) reserved for focus and the active navigation state.
 */
const config: Config = {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
    "./lib/**/*.{ts,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        paper: "#FBFAF8",
        panel: "#EFEDE8",
        ink: "#171512",
        "ink-70": "#4A443E",
        muted: "#6B6560",
        line: "#E3DFD8",
        "line-strong": "#CFC9C0",
        accent: "#6E3B52",
        "accent-soft": "#F4ECEF",
        danger: "#8C2F26",
      },
      fontFamily: {
        sans: ["var(--font-sans)", "ui-sans-serif", "system-ui", "sans-serif"],
        serif: ["var(--font-serif)", "ui-serif", "Georgia", "serif"],
      },
      fontSize: {
        "2xs": ["0.6875rem", { lineHeight: "1rem" }],
        xs: ["0.75rem", { lineHeight: "1.125rem" }],
        sm: ["0.8125rem", { lineHeight: "1.25rem" }],
        base: ["0.875rem", { lineHeight: "1.375rem" }],
      },
      borderRadius: {
        DEFAULT: "3px",
        sm: "2px",
        md: "4px",
      },
      letterSpacing: {
        tightish: "-0.011em",
      },
    },
  },
  plugins: [],
};

export default config;
