"use client";

import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { usePathname } from "next/navigation";
import { Menu } from "lucide-react";
import { Sheet } from "@/components/ui/sheet";
import type { UserRole } from "@/lib/tenant";
import { PrimaryNav } from "./primary-nav";
import { BottomNav, bottomNavHidden } from "./bottom-nav";

/**
 * The phone shell: a bottom bar with the operational doors and "Menü", which opens the
 * full navigation sheet (business plate on top, grouped 44px rows, the account at the
 * foot; closes on navigation). On screens whose bottom belongs to a task bar (POS,
 * counting, intake) the bottom bar steps aside and a small top-bar trigger opens the
 * same sheet — never two bars, never two hamburgers.
 */
export function MobileNav({ role, badges, plate, account }: { role: UserRole; badges?: Record<string, number>; plate: React.ReactNode; account: React.ReactNode }) {
  const [open, setOpen] = useState(false);
  const [mounted, setMounted] = useState(false);
  const pathname = usePathname();
  const topTrigger = bottomNavHidden(pathname);
  useEffect(() => setMounted(true), []);

  return (
    <>
      {topTrigger ? (
        <button
          type="button"
          onClick={() => setOpen(true)}
          aria-label="Menüyü aç"
          aria-haspopup="dialog"
          aria-expanded={open}
          className="inline-flex h-11 w-11 items-center justify-center rounded text-text-secondary hover:bg-surface-muted hover:text-text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring lg:hidden"
        >
          <Menu aria-hidden className="h-5 w-5 stroke-[1.5]" />
        </button>
      ) : null}

      {/* portalled to <body>: the top bar's backdrop-filter would otherwise become the
          containing block of a fixed child and pin the bar to the top of the screen */}
      {mounted ? createPortal(<BottomNav role={role} badges={badges} onMenu={() => setOpen(true)} />, document.body) : null}

      <Sheet open={open} onClose={() => setOpen(false)} title="Menü" className="w-[min(22rem,90vw)]">
        <div className="flex h-full flex-col">
          <div className="border-b border-border px-4 py-4">{plate}</div>
          <div className="px-2 py-3">
            <PrimaryNav role={role} badges={badges} onNavigate={() => setOpen(false)} dense />
          </div>
          <div className="mt-auto border-t border-border px-4 py-4" style={{ paddingBottom: "max(1rem, env(safe-area-inset-bottom))" }}>{account}</div>
        </div>
      </Sheet>
    </>
  );
}
