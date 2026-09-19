"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { UserRole } from "@/lib/tenant";
import { cn } from "@/lib/utils";
import { navGroupsFor, isNavActive } from "./nav-items";

/**
 * Grouped primary navigation, filtered by role. The active item sits on a quiet
 * linen-plum surface with a plum marker on the left; everything else is plain text —
 * no pills, no cards. Optional badges carry actionable counts only (e.g. new online
 * orders), passed in by the server shell from a bounded read.
 */
export function PrimaryNav({
  role,
  badges = {},
  onNavigate,
  dense = false,
}: {
  role: UserRole;
  badges?: Record<string, number>;
  onNavigate?: () => void;
  /** phone menu: 44px rows */
  dense?: boolean;
}) {
  const pathname = usePathname();
  const groups = navGroupsFor(role);
  const all = groups.flatMap((g) => g.items.map((i) => i.href));

  return (
    <nav aria-label="Ana menü" className="space-y-5">
      {groups.map((group) => (
        <div key={group.label}>
          <p className="mb-1 px-3 text-2xs uppercase tracking-wide text-text-muted">{group.label}</p>
          <ul className="space-y-px">
            {group.items.map(({ label, icon: Icon, href }) => {
              const active = isNavActive(pathname, href, all);
              const badge = badges[href];
              return (
                <li key={href}>
                  <Link
                    href={href}
                    onClick={onNavigate}
                    aria-current={active ? "page" : undefined}
                    className={cn(
                      "relative flex items-center gap-2.5 rounded px-3 text-sm transition-colors",
                      dense ? "min-h-11 py-2.5" : "min-h-9 py-1.5",
                      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                      active
                        ? "bg-accent-muted/70 font-medium text-accent before:absolute before:inset-y-1.5 before:left-0 before:w-0.5 before:rounded-full before:bg-accent"
                        : "text-text-secondary hover:bg-surface-muted hover:text-text-primary",
                    )}
                  >
                    <Icon aria-hidden className={cn("h-4 w-4 shrink-0 stroke-[1.5]", active ? "text-accent" : "text-text-muted")} />
                    <span className="min-w-0 flex-1 truncate">{label}</span>
                    {badge && badge > 0 ? (
                      <span className="rounded-full bg-accent px-1.5 py-0.5 text-2xs font-medium leading-none text-accent-foreground" data-numeric aria-label={`${badge} yeni`}>
                        {badge > 99 ? "99+" : badge}
                      </span>
                    ) : null}
                  </Link>
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </nav>
  );
}
