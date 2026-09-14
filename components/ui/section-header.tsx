import * as React from "react";
import { cn } from "@/lib/utils";

/** A section inside a page: small title, optional count or note, an optional quiet action. */
export function SectionHeader({
  title,
  meta,
  action,
  className,
}: {
  title: React.ReactNode;
  meta?: React.ReactNode;
  action?: React.ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1", className)}>
      <div className="flex items-baseline gap-2">
        <h2 className="text-sm font-medium tracking-tightish text-text-primary">{title}</h2>
        {meta ? (
          <span className="text-xs text-text-muted" data-numeric>
            {meta}
          </span>
        ) : null}
      </div>
      {action ? <div className="text-xs">{action}</div> : null}
    </div>
  );
}
