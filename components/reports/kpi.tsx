import * as React from "react";
import { Stat } from "@/components/ui/stat";
import { deltaPct, fmtDelta } from "@/components/reports/format";
import { cn } from "@/lib/utils";

/**
 * A KPI tile with an honest comparison: the previous period's value and the change,
 * shown only when the previous period actually had data. No arrows, no colour coding —
 * a drop in returns is good and a drop in sales is bad, and the number says which.
 */
export function Kpi({
  label,
  value,
  current,
  previous,
  format,
  hint,
  hasPrevious,
}: {
  label: React.ReactNode;
  value: React.ReactNode;
  current?: number | null;
  previous?: number | null;
  format?: (v: number | null | undefined) => string;
  hint?: React.ReactNode;
  /** Whether the previous window had any activity at all; without it no comparison is shown. */
  hasPrevious?: boolean;
}) {
  let compare: React.ReactNode = hint;
  if (hasPrevious && current !== undefined && current !== null && previous !== undefined && previous !== null && format) {
    const d = deltaPct(current, previous);
    compare = (
      <>
        önceki dönem {format(previous)}
        {d !== null ? <span className="ml-1 text-text-secondary">({fmtDelta(d)})</span> : null}
      </>
    );
  }
  return <Stat label={label} value={value} hint={compare} />;
}

export function KpiStrip({ children, className }: { children: React.ReactNode; className?: string }) {
  return <div className={cn("grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4", className)}>{children}</div>;
}
