import * as React from "react";
import Link from "next/link";
import { cn } from "@/lib/utils";

/**
 * The one page pattern: an optional context line above, the title, one short supporting
 * sentence, the primary action to the right on desktop and below on a phone.
 *
 * Titles are sans. The serif is for editorial moments (the dashboard welcome), not for
 * "Ürünler" or "Ayarlar".
 */
export function PageHeader({
  eyebrow,
  title,
  description,
  actions,
  className,
}: {
  /** Context above the title — a parent link or a short qualifier, sentence case. */
  eyebrow?: React.ReactNode | { href: string; label: string };
  title: React.ReactNode;
  description?: React.ReactNode;
  actions?: React.ReactNode;
  className?: string;
}) {
  const context =
    eyebrow && typeof eyebrow === "object" && "href" in eyebrow ? (
      <Link
        href={eyebrow.href}
        className="text-xs text-text-muted underline-offset-4 hover:text-text-primary hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        {eyebrow.label}
      </Link>
    ) : (
      eyebrow
    );

  return (
    <header className={cn("flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between", className)}>
      <div className="min-w-0">
        {context ? <div className="mb-2 text-xs text-text-muted">{context}</div> : null}
        <h1 className="text-xl font-medium leading-tight tracking-tightish text-text-primary">{title}</h1>
        {description ? (
          <p className="mt-1.5 max-w-prose text-sm leading-relaxed text-text-muted">{description}</p>
        ) : null}
      </div>
      {actions ? <div className="flex shrink-0 flex-wrap items-center gap-2">{actions}</div> : null}
    </header>
  );
}
