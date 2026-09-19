"use client";

import { useState } from "react";
import Link from "next/link";
import { MoreHorizontal } from "lucide-react";

/**
 * The quiet menu next to "Ürün ekle": the legacy product form stays reachable as
 * "Gelişmiş ürün ekleme" without competing with the guided flow.
 */
export function AdvancedAddMenu() {
  const [open, setOpen] = useState(false);
  return (
    <div className="relative">
      <button
        type="button"
        aria-label="Diğer seçenekler"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
        onBlur={(e) => {
          if (!e.currentTarget.parentElement?.contains(e.relatedTarget as Node)) setOpen(false);
        }}
        className="inline-flex h-11 w-11 items-center justify-center rounded border border-border-strong bg-surface text-text-muted hover:bg-surface-muted hover:text-text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring sm:h-10 sm:w-10"
        data-testid="advanced-add-menu"
      >
        <MoreHorizontal aria-hidden className="h-4 w-4" />
      </button>
      {open ? (
        <ul role="menu" className="absolute right-0 z-20 mt-1 w-56 rounded border border-border bg-surface py-1 text-sm shadow-md">
          <li role="none">
            <Link role="menuitem" href="/app/urunler/yeni" onClick={() => setOpen(false)} className="flex min-h-10 items-center px-3 hover:bg-surface-muted">
              Gelişmiş ürün ekleme
            </Link>
          </li>
        </ul>
      ) : null}
    </div>
  );
}
