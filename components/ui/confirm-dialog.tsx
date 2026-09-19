"use client";

import * as React from "react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

/**
 * The one confirmation pattern: a centred native <dialog> (focus trap, Escape and the
 * backdrop come from the browser), a plain question as the title, one sentence on what
 * happens, a destructive or primary confirm button and "Vazgeç". A destructive action
 * never runs from a casual click: it always passes through here.
 */
export function ConfirmDialog({
  open,
  onClose,
  title,
  description,
  confirmLabel,
  cancelLabel = "Vazgeç",
  destructive = false,
  busy = false,
  onConfirm,
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  description?: React.ReactNode;
  confirmLabel: string;
  cancelLabel?: string;
  destructive?: boolean;
  busy?: boolean;
  onConfirm: () => void;
  /** Optional extra content (a reason field, a summary) between the description and the buttons. */
  children?: React.ReactNode;
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
      aria-labelledby="confirm-title"
      onClose={onClose}
      onClick={(e) => {
        if (e.target === e.currentTarget && !busy) onClose();
      }}
      className={cn(
        "m-auto w-[min(26rem,calc(100vw-2rem))] rounded border border-border bg-surface p-0 text-text-primary shadow-md",
        "backdrop:bg-black/40",
      )}
    >
      <div className="space-y-4 p-5">
        <div className="space-y-1.5">
          <h2 id="confirm-title" className="text-base font-medium leading-snug">{title}</h2>
          {description ? <p className="text-sm leading-relaxed text-text-secondary">{description}</p> : null}
        </div>
        {children}
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button type="button" variant="ghost" onClick={onClose} disabled={busy}>
            {cancelLabel}
          </Button>
          <Button type="button" variant={destructive ? "danger" : "solid"} onClick={onConfirm} disabled={busy} autoFocus={!destructive}>
            {busy ? "…" : confirmLabel}
          </Button>
        </div>
      </div>
    </dialog>
  );
}
