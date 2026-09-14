"use client";

import { useState } from "react";
import { Menu } from "lucide-react";
import { Sheet } from "@/components/ui/sheet";
import { PrimaryNav } from "./primary-nav";

/**
 * Below the desktop breakpoint the rail becomes a drawer. The trigger sits in the top
 * bar; the drawer carries the navigation and whatever the layout passes as `footer`
 * (the business plate and the account block), so nothing is lost on a phone.
 */
export function MobileNav({ footer }: { footer: React.ReactNode }) {
  const [open, setOpen] = useState(false);

  return (
    <>
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

      <Sheet open={open} onClose={() => setOpen(false)} title="Menü">
        <div className="flex h-full flex-col">
          <div className="px-2 py-4">
            <PrimaryNav onNavigate={() => setOpen(false)} showInert={false} />
          </div>
          <div className="mt-auto space-y-4 border-t border-border px-4 py-4">{footer}</div>
        </div>
      </Sheet>
    </>
  );
}
