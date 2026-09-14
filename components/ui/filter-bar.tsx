import * as React from "react";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

/**
 * GET filter form above a list. Fields flow in a grid; the submit and the "clear" link
 * sit on their own row. Purely presentational — the page owns the params and the query.
 */
export function FilterBar({
  children,
  clearHref,
  hasFilter,
  columns = 5,
  className,
}: {
  children: React.ReactNode;
  clearHref: string;
  hasFilter: boolean;
  columns?: 4 | 5;
  className?: string;
}) {
  return (
    <form
      method="get"
      className={cn(
        "grid grid-cols-2 gap-3 rounded border border-border bg-background/60 p-4",
        columns === 5 ? "lg:grid-cols-5" : "lg:grid-cols-4",
        className,
      )}
    >
      {children}
      <div className={cn("col-span-2 flex items-center gap-3", columns === 5 ? "lg:col-span-5" : "lg:col-span-4")}>
        <Button type="submit" size="sm" variant="outline">
          Filtrele
        </Button>
        {hasFilter ? (
          <Link
            href={clearHref}
            className="text-xs text-text-muted underline-offset-4 hover:text-text-primary hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            Filtreleri temizle
          </Link>
        ) : null}
      </div>
    </form>
  );
}

/** A field slot inside the FilterBar; `wide` spans the search column pair. */
export function FilterField({ children, wide = false }: { children: React.ReactNode; wide?: boolean }) {
  return <div className={cn("space-y-1.5", wide && "col-span-2")}>{children}</div>;
}
