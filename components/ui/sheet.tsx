"use client";

import * as React from "react";
import { X } from "lucide-react";
import { cn } from "@/lib/utils";

/**
 * Side sheet on the native <dialog>: the browser owns the focus trap, Escape, the
 * backdrop and inertness of the page behind — no overlay library needed. Used for the
 * navigation drawer below the desktop breakpoint.
 */
export function Sheet({
  open,
  onClose,
  title,
  side = "left",
  children,
  className,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  side?: "left" | "right";
  children: React.ReactNode;
  className?: string;
}) {
  const ref = React.useRef<HTMLDialogElement>(null);

  React.useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (open && !el.open) el.showModal();
    if (!open && el.open) el.close();
  }, [open]);

  return (
    <dialog
      ref={ref}
      aria-label={title}
      onClose={onClose}
      onClick={(e) => {
        // A click on the backdrop lands on the dialog element itself, not on its content.
        if (e.target === e.currentTarget) onClose();
      }}
      className={cn(
        "m-0 h-dvh max-h-dvh w-[min(20rem,88vw)] max-w-none bg-surface p-0 text-text-primary shadow-md",
        "border-border backdrop:bg-transparent",
        side === "left" ? "mr-auto border-r" : "ml-auto border-l",
        className,
      )}
    >
      <div className="flex h-full flex-col">
        <div className="flex items-center justify-between border-b border-border px-4 py-3">
          <span className="text-sm font-medium">{title}</span>
          <button
            type="button"
            onClick={onClose}
            aria-label="Kapat"
            className="inline-flex h-9 w-9 items-center justify-center rounded text-text-muted hover:bg-surface-muted hover:text-text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            <X aria-hidden className="h-4 w-4" />
          </button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto">{children}</div>
      </div>
    </dialog>
  );
}
