import * as React from "react";
import { cn } from "@/lib/utils";

/**
 * Empty, first-use and "not for this role" surfaces share one shape: what this is, what
 * to do next, one action. Calm language, no implementation detail.
 *
 * `editorial` sets the title in the serif — for a first-use moment on a fresh tenant,
 * not for "no rows match these filters".
 */
export function EmptyState({
  title,
  description,
  action,
  editorial = false,
  compact = false,
  className,
}: {
  title: React.ReactNode;
  description?: React.ReactNode;
  action?: React.ReactNode;
  editorial?: boolean;
  compact?: boolean;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-col items-center rounded border border-dashed border-border-strong bg-surface/60 px-6 text-center",
        compact ? "py-8" : "py-14",
        className,
      )}
    >
      <p
        className={cn(
          editorial
            ? "font-serif text-3xl font-medium leading-tight text-text-primary"
            : "text-sm font-medium text-text-primary",
        )}
      >
        {title}
      </p>
      {description ? (
        <p className="mt-2 max-w-md text-xs leading-relaxed text-text-muted sm:text-sm">{description}</p>
      ) : null}
      {action ? <div className="mt-5">{action}</div> : null}
    </div>
  );
}
