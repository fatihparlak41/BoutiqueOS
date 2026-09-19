"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { Menu } from "lucide-react";
import type { UserRole } from "@/lib/tenant";
import { cn } from "@/lib/utils";
import { bottomNavFor, isNavActive, NAV_GROUPS } from "./nav-items";

/**
 * The phone's operational bar: up to four doors the role can open plus "Menü", which
 * opens the full navigation sheet. It respects the home-indicator safe area and steps
 * aside on screens that own the bottom of the viewport with a task bar (POS terminal,
 * counting, the product intake), so two bars never stack.
 */
export const BOTTOM_NAV_HIDDEN_ON = [/^\/app\/pos$/, /^\/app\/pos\/iade/, /^\/app\/stok\/sayim\/[0-9a-f-]{36}/, /^\/app\/urunler\/katalog-ekle/, /^\/app\/rezervasyonlar\/yeni/];

export function bottomNavHidden(pathname: string): boolean {
  return BOTTOM_NAV_HIDDEN_ON.some((re) => re.test(pathname));
}

export function BottomNav({ role, badges = {}, onMenu }: { role: UserRole; badges?: Record<string, number>; onMenu: () => void }) {
  const pathname = usePathname();
  if (bottomNavHidden(pathname)) return null;
  const items = bottomNavFor(role);
  const all = NAV_GROUPS.flatMap((g) => g.items.map((i) => i.href));

  return (
    <nav
      aria-label="Hızlı menü"
      data-testid="bottom-nav"
      className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-background/95 backdrop-blur lg:hidden"
      style={{ paddingBottom: "env(safe-area-inset-bottom)" }}
    >
      <ul className="grid" style={{ gridTemplateColumns: `repeat(${items.length + 1}, minmax(0, 1fr))` }}>
        {items.map(({ label, icon: Icon, href }) => {
          const active = isNavActive(pathname, href, all);
          const badge = badges[href];
          return (
            <li key={href}>
              <Link
                href={href}
                aria-current={active ? "page" : undefined}
                className={cn(
                  "relative flex min-h-14 flex-col items-center justify-center gap-1 px-1 text-2xs transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring",
                  active ? "text-accent" : "text-text-secondary",
                )}
              >
                <span className={cn("relative rounded-full px-3 py-0.5", active && "bg-accent-muted")}>
                  <Icon aria-hidden className="h-5 w-5 stroke-[1.5]" />
                  {badge && badge > 0 ? (
                    <span className="absolute -right-1 -top-1 min-w-4 rounded-full bg-accent px-1 text-center text-[10px] font-medium leading-4 text-accent-foreground" data-numeric>
                      {badge > 9 ? "9+" : badge}
                    </span>
                  ) : null}
                </span>
                <span className="max-w-full truncate">{label}</span>
              </Link>
            </li>
          );
        })}
        <li>
          <button
            type="button"
            onClick={onMenu}
            aria-label="Menüyü aç"
            className="flex min-h-14 w-full flex-col items-center justify-center gap-1 px-1 text-2xs text-text-secondary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
          >
            <span className="rounded-full px-3 py-0.5"><Menu aria-hidden className="h-5 w-5 stroke-[1.5]" /></span>
            Menü
          </button>
        </li>
      </ul>
    </nav>
  );
}
