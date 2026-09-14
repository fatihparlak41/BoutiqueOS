import * as React from "react";
import { cn } from "@/lib/utils";

/**
 * Dense operational table. Hairlines, tabular numbers, no zebra, a quiet hover.
 *
 * TableShell owns the one place horizontal scrolling is allowed: a wide table scrolls
 * inside its own box on a narrow screen and the page never does. `minWidth` states how
 * wide the table needs to be before it starts to scroll.
 */
export function TableShell({
  children,
  minWidth = "48rem",
  footer,
  className,
}: {
  children: React.ReactNode;
  minWidth?: string;
  footer?: React.ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("space-y-3", className)}>
      <div className="relative -mx-5 overflow-x-auto px-5 sm:mx-0 sm:px-0">
        <table className="w-full border-collapse text-sm" style={{ minWidth }}>
          {children}
        </table>
      </div>
      {footer ? (
        <p className="text-2xs text-text-muted" data-numeric>
          {footer}
        </p>
      ) : null}
    </div>
  );
}

export function THead({ children }: { children: React.ReactNode }) {
  return (
    <thead>
      <tr className="border-y border-border text-left text-xs text-text-muted">{children}</tr>
    </thead>
  );
}

export function TH({
  children,
  align = "left",
  className,
}: {
  children?: React.ReactNode;
  align?: "left" | "right";
  className?: string;
}) {
  return (
    <th scope="col" className={cn("py-2 pr-4 font-medium last:pr-0", align === "right" && "text-right", className)}>
      {children}
    </th>
  );
}

export function TBody({ children }: { children: React.ReactNode }) {
  return <tbody className="divide-y divide-border">{children}</tbody>;
}

export function TR({ children, className }: { children: React.ReactNode; className?: string }) {
  return <tr className={cn("align-top transition-colors hover:bg-surface-muted/60", className)}>{children}</tr>;
}

export function TD({
  children,
  align = "left",
  numeric = false,
  muted = false,
  nowrap = false,
  className,
}: {
  children?: React.ReactNode;
  align?: "left" | "right";
  numeric?: boolean;
  muted?: boolean;
  /** Dates, codes and short names that must not break into two lines. */
  nowrap?: boolean;
  className?: string;
}) {
  return (
    <td
      className={cn(
        "py-2.5 pr-4 last:pr-0",
        align === "right" && "text-right",
        nowrap && "whitespace-nowrap",
        muted ? "text-text-secondary" : "text-text-primary",
        className,
      )}
      data-numeric={numeric || undefined}
    >
      {children}
    </td>
  );
}

/** A primary cell: the linked name on top, a quiet identifier underneath. */
export function CellTitle({
  children,
  sub,
  subNumeric = false,
}: {
  children: React.ReactNode;
  sub?: React.ReactNode;
  subNumeric?: boolean;
}) {
  return (
    <>
      <span className="font-medium text-text-primary">{children}</span>
      {sub ? (
        <span className="mt-0.5 block text-2xs text-text-muted" data-numeric={subNumeric || undefined}>
          {sub}
        </span>
      ) : null}
    </>
  );
}

export const rowLinkClass =
  "font-medium text-text-primary underline-offset-4 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring";
