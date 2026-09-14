"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";
import { NAV_GROUPS, isNavActive } from "./nav-items";

/**
 * Grouped primary navigation. The active item is marked by the plum text and a thin rule
 * on the left, not a filled block — the accent stays a mark, not a surface.
 *
 * Inert modules appear only where there is room for them (the desktop rail): on a phone
 * the drawer lists what can actually be opened.
 */
export function PrimaryNav({ onNavigate, showInert = true }: { onNavigate?: () => void; showInert?: boolean }) {
  const pathname = usePathname();

  return (
    <nav aria-label="Ana menü" className="space-y-5">
      {NAV_GROUPS.map((group) => {
        const items = showInert ? group.items : group.items.filter((i) => i.href);
        if (items.length === 0) return null;
        return (
          <div key={group.label}>
            <p className="mb-1 px-3 text-2xs text-text-muted">{group.label}</p>
            <ul className="space-y-px">
              {items.map(({ label, icon: Icon, href }) => {
                const active = href ? isNavActive(pathname, href) : false;
                return (
                  <li key={label}>
                    {href ? (
                      <Link
                        href={href}
                        onClick={onNavigate}
                        aria-current={active ? "page" : undefined}
                        className={cn(
                          "relative flex min-h-10 items-center gap-2.5 rounded px-3 py-2 text-sm transition-colors",
                          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                          active
                            ? "font-medium text-accent before:absolute before:inset-y-2 before:left-0 before:w-0.5 before:rounded-full before:bg-accent"
                            : "text-text-secondary hover:bg-surface-muted hover:text-text-primary",
                        )}
                      >
                        <Icon aria-hidden className="h-4 w-4 shrink-0 stroke-[1.5]" />
                        <span className="truncate">{label}</span>
                      </Link>
                    ) : (
                      <span
                        aria-disabled="true"
                        title="Bu bölüm henüz açılmadı"
                        className="flex min-h-10 cursor-not-allowed items-center gap-2.5 rounded px-3 py-2 text-sm text-text-muted/60"
                      >
                        <Icon aria-hidden className="h-4 w-4 shrink-0 stroke-[1.5]" />
                        <span className="truncate">{label}</span>
                      </span>
                    )}
                  </li>
                );
              })}
            </ul>
          </div>
        );
      })}
    </nav>
  );
}
