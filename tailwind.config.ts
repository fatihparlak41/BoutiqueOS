import type { Config } from "tailwindcss";

/**
 * BoutiqueOS design tokens.
 *
 * Colours resolve to the CSS variables declared in app/globals.css, so the palette lives in
 * one place and components use semantic names. The short aliases (paper, panel, ink, line,
 * muted, accent-soft) are the names the earlier phases were written against and map onto
 * the same variables — one palette, two vocabularies, no drift.
 *
 * Warm linen ground, hairlines instead of shadows, small radii, one plum accent.
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
        // semantic
        background: "var(--background)",
        foreground: "var(--foreground)",
        surface: {
          DEFAULT: "var(--surface)",
          elevated: "var(--surface-elevated)",
          muted: "var(--surface-muted)",
        },
        border: {
          DEFAULT: "var(--border)",
          strong: "var(--border-strong)",
        },
        primary: {
          DEFAULT: "var(--primary)",
          hover: "var(--primary-hover)",
          foreground: "var(--primary-foreground)",
        },
        accent: {
          DEFAULT: "var(--accent)",
          hover: "var(--accent-hover)",
          muted: "var(--accent-muted)",
          foreground: "var(--accent-foreground)",
          // alias kept for the earlier phases
          soft: "var(--accent-muted)",
        },
        olive: {
          DEFAULT: "var(--olive)",
          muted: "var(--olive-muted)",
        },
        success: { DEFAULT: "var(--success)", muted: "var(--success-muted)" },
        warning: { DEFAULT: "var(--warning)", muted: "var(--warning-muted)" },
        danger: { DEFAULT: "var(--danger)", muted: "var(--danger-muted)" },
        text: {
          primary: "var(--text-primary)",
          secondary: "var(--text-secondary)",
          muted: "var(--text-muted)",
        },
        ring: "var(--ring)",

        // aliases used by phases 1–4 (same variables)
        paper: "var(--surface)",
        panel: "var(--surface-muted)",
        ink: "var(--text-primary)",
        "ink-70": "var(--text-secondary)",
        muted: "var(--text-muted)",
        line: "var(--border)",
        "line-strong": "var(--border-strong)",
      },
      ringColor: {
        DEFAULT: "var(--ring)",
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
        lg: ["1rem", { lineHeight: "1.5rem" }],
        xl: ["1.25rem", { lineHeight: "1.6rem" }],
        "2xl": ["1.625rem", { lineHeight: "2rem" }],
        // editorial sizes for the serif: Cormorant runs small, so it is set larger
        "3xl": ["2rem", { lineHeight: "2.25rem" }],
        "4xl": ["2.5rem", { lineHeight: "2.75rem" }],
      },
      borderRadius: {
        sm: "var(--radius-sm)",
        DEFAULT: "var(--radius)",
        md: "var(--radius-md)",
        lg: "var(--radius-lg)",
      },
      boxShadow: {
        sm: "var(--shadow-sm)",
        md: "var(--shadow-md)",
      },
      letterSpacing: {
        tightish: "-0.011em",
      },
      maxWidth: {
        content: "72rem",
        prose: "38rem",
      },
    },
  },
  plugins: [],
};

export default config;
