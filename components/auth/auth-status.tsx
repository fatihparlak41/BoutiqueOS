import * as React from "react";
import { cn } from "@/lib/utils";

/**
 * One shape for every auth outcome that is not a form: an expired or used link, a
 * refused recovery, a temporary delay, a plain failure. Title, one explanation, one
 * action. Tone is the meaning; the text never carries a code, a provider message or a
 * token.
 */
export function AuthStatus({
  tone = "neutral",
  title,
  description,
  action,
  className,
  live = false,
}: {
  tone?: "neutral" | "success" | "warning" | "danger";
  title: React.ReactNode;
  description?: React.ReactNode;
  action?: React.ReactNode;
  className?: string;
  /** Announce changes to assistive tech (a transition that resolves on its own). */
  live?: boolean;
}) {
  const border = {
    neutral: "border-border-strong",
    success: "border-success/40",
    warning: "border-warning/40",
    danger: "border-danger/40",
  }[tone];

  return (
    <div
      role={live ? "status" : undefined}
      aria-live={live ? "polite" : undefined}
      className={cn("border-l-2 pl-4", border, className)}
    >
      <p className="text-sm font-medium text-text-primary">{title}</p>
      {description ? <p className="mt-1 text-sm leading-relaxed text-text-muted">{description}</p> : null}
      {action ? <div className="mt-4">{action}</div> : null}
    </div>
  );
}

/** Inline form error, associated to its field(s) via the id the caller passes. */
export function FormAlert({ id, children }: { id?: string; children: React.ReactNode }) {
  return (
    <p
      id={id}
      role="alert"
      className="rounded border border-danger/30 bg-danger-muted/50 px-3 py-2 text-sm leading-relaxed text-danger"
    >
      {children}
    </p>
  );
}
