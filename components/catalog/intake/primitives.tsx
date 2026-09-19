"use client";

import { cn } from "@/lib/utils";

/**
 * Small pieces of the product intake: the stepper, the touch-sized chip, the inline
 * notices, the labelled field. All sized for a phone held in one hand in the shop;
 * desktop gets the same controls with more room. Photos live in the shared PhotoField.
 */

export const STEP_TITLES = ["Ürün", "Renk & Beden", "Barkod", "Kontrol"] as const;
export type Step = 1 | 2 | 3 | 4;

/**
 * Where am I, what am I doing. Desktop: four labelled steps. Phone: "Adım 2 / 4 ·
 * Renk & Beden" over a compact progress bar — never four anonymous circles.
 */
export function Stepper({ step }: { step: Step }) {
  const total = STEP_TITLES.length;
  return (
    <div aria-label="Adımlar">
      <div className="sm:hidden">
        <p className="flex items-baseline justify-between text-sm">
          <span className="font-medium text-text-primary">{STEP_TITLES[step - 1]}</span>
          <span className="text-xs text-text-muted" data-numeric>Adım {step} / {total}</span>
        </p>
        <div className="mt-2 flex gap-1" role="progressbar" aria-valuenow={step} aria-valuemin={1} aria-valuemax={total}>
          {STEP_TITLES.map((t, i) => (
            <span key={t} className={cn("h-1 flex-1 rounded-full", i < step ? "bg-accent" : "bg-border")} />
          ))}
        </div>
      </div>
      <ol className="hidden items-center gap-2 text-xs sm:flex">
        {STEP_TITLES.map((title, i) => {
          const n = i + 1;
          const state = n === step ? "current" : n < step ? "done" : "todo";
          return (
            <li key={title} className="flex items-center gap-2">
              <span
                aria-current={state === "current" ? "step" : undefined}
                className={cn(
                  "inline-flex h-7 min-w-7 items-center justify-center rounded-full border px-2 font-medium",
                  state === "current" && "border-accent bg-accent text-accent-foreground",
                  state === "done" && "border-accent/40 bg-accent-muted text-accent",
                  state === "todo" && "border-border text-text-muted",
                )}
              >
                {n}
              </span>
              <span className={cn(state === "current" ? "font-medium text-text-primary" : "text-text-muted")}>{title}</span>
              {n < total ? <span aria-hidden className="mx-1 h-px w-6 bg-border" /> : null}
            </li>
          );
        })}
      </ol>
    </div>
  );
}

/** A selectable value: 44px tall everywhere, plum when on. */
export function Chip({
  on,
  onClick,
  children,
  disabled,
  title,
}: {
  on: boolean;
  onClick: () => void;
  children: React.ReactNode;
  disabled?: boolean;
  title?: string;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={on}
      disabled={disabled}
      title={title}
      className={cn(
        "inline-flex min-h-11 min-w-11 items-center justify-center rounded border px-3.5 text-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
        on ? "border-accent bg-accent-muted font-medium text-accent" : "border-border-strong bg-surface text-text-secondary hover:border-text-muted",
        disabled && "opacity-50",
      )}
    >
      {children}
    </button>
  );
}

export function Notice({ tone, children }: { tone: "danger" | "warning" | "success" | "info"; children: React.ReactNode }) {
  return (
    <div
      role={tone === "danger" ? "alert" : "status"}
      className={cn(
        "rounded border px-3 py-2.5 text-sm",
        tone === "danger" && "border-danger/30 bg-danger-muted/50 text-danger",
        tone === "warning" && "border-warning/30 bg-warning-muted text-text-primary",
        tone === "success" && "border-success/25 bg-success-muted text-success",
        tone === "info" && "border-border bg-surface-muted/50 text-text-secondary",
      )}
    >
      {children}
    </div>
  );
}

export function Field({ label, htmlFor, hint, optional, children }: { label: string; htmlFor: string; hint?: string; optional?: boolean; children: React.ReactNode }) {
  return (
    <div className="space-y-1.5">
      <label htmlFor={htmlFor} className="block text-sm font-medium text-text-primary">
        {label}
        {optional ? <span className="ml-1.5 text-xs font-normal text-text-muted">isteğe bağlı</span> : null}
      </label>
      {children}
      {hint ? <p className="text-xs text-text-muted">{hint}</p> : null}
    </div>
  );
}
