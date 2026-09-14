import * as React from "react";
import Link from "next/link";
import { cn } from "@/lib/utils";

/**
 * Compact metric: a label, one number, an optional qualifier. Numbers are tabular and
 * sans; no sparkline, no delta arrow, no colour unless the value itself is a state.
 */
export function Stat({
  label,
  value,
  hint,
  href,
  className,
}: {
  label: React.ReactNode;
  value: React.ReactNode;
  hint?: React.ReactNode;
  href?: string;
  className?: string;
}) {
  const body = (
    <>
      <dt className="text-xs text-text-muted">{label}</dt>
      <dd className="mt-1 text-2xl font-medium leading-none tracking-tightish text-text-primary" data-numeric>
        {value}
      </dd>
      {hint ? <dd className="mt-1.5 text-2xs text-text-muted">{hint}</dd> : null}
    </>
  );

  const base = "rounded border border-border bg-surface px-4 py-3";

  if (href) {
    return (
      <div className={cn(base, "transition-colors hover:border-border-strong", className)}>
        <Link
          href={href}
          className="block focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-surface"
        >
          <dl>{body}</dl>
        </Link>
      </div>
    );
  }

  return (
    <dl className={cn(base, className)}>
      {body}
    </dl>
  );
}

export function StatGrid({ children, className }: { children: React.ReactNode; className?: string }) {
  return <div className={cn("grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4", className)}>{children}</div>;
}
