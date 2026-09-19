"use client";

import * as React from "react";
import { CheckCircle2, Info, X, XCircle } from "lucide-react";
import { cn } from "@/lib/utils";

/**
 * One toast system. `useToast()` returns `toast({ title, description?, tone?, action? })`;
 * the viewport sits bottom-centre on a phone (above the sticky action bars) and
 * bottom-right on desktop. Toasts announce via role="status" and dismiss themselves
 * after a few seconds; a toast with an action stays a little longer. No motion beyond a
 * short fade, and none at all when the person prefers reduced motion.
 */
export type ToastTone = "success" | "info" | "danger";
export type ToastInput = {
  title: string;
  description?: string;
  tone?: ToastTone;
  action?: { label: string; href?: string; onClick?: () => void };
  /** ms; defaults to 4000, 7000 with an action */
  duration?: number;
};
type ToastItem = ToastInput & { id: number };

const ToastContext = React.createContext<((t: ToastInput) => void) | null>(null);

export function useToast() {
  const push = React.useContext(ToastContext);
  return React.useMemo(() => ({ toast: (t: ToastInput) => push?.(t) }), [push]);
}

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [items, setItems] = React.useState<ToastItem[]>([]);
  const seq = React.useRef(0);

  const dismiss = React.useCallback((id: number) => setItems((prev) => prev.filter((t) => t.id !== id)), []);
  const push = React.useCallback(
    (t: ToastInput) => {
      const id = ++seq.current;
      setItems((prev) => [...prev.slice(-2), { ...t, id }]);
      const ms = t.duration ?? (t.action ? 7000 : 4000);
      window.setTimeout(() => dismiss(id), ms);
    },
    [dismiss],
  );

  return (
    <ToastContext.Provider value={push}>
      {children}
      <div aria-live="polite" className="pointer-events-none fixed inset-x-0 bottom-20 z-50 flex flex-col items-center gap-2 px-4 sm:bottom-6 sm:items-end sm:px-6">
        {items.map((t) => {
          const Icon = t.tone === "danger" ? XCircle : t.tone === "info" ? Info : CheckCircle2;
          return (
            <div
              key={t.id}
              role="status"
              className={cn(
                "pointer-events-auto flex w-full max-w-sm items-start gap-3 rounded border bg-surface px-3 py-2.5 text-sm text-text-primary shadow-md",
                t.tone === "danger" ? "border-danger/40" : "border-border-strong",
              )}
            >
              <Icon aria-hidden className={cn("mt-0.5 h-4 w-4 shrink-0", t.tone === "danger" ? "text-danger" : t.tone === "info" ? "text-text-muted" : "text-success")} />
              <div className="min-w-0 flex-1">
                <p className="font-medium leading-snug">{t.title}</p>
                {t.description ? <p className="mt-0.5 text-xs text-text-secondary">{t.description}</p> : null}
                {t.action ? (
                  t.action.href ? (
                    <a href={t.action.href} className="mt-1 inline-block text-xs font-medium text-accent underline-offset-4 hover:underline">{t.action.label}</a>
                  ) : (
                    <button type="button" onClick={() => { t.action?.onClick?.(); dismiss(t.id); }} className="mt-1 text-xs font-medium text-accent underline-offset-4 hover:underline">{t.action.label}</button>
                  )
                ) : null}
              </div>
              <button type="button" onClick={() => dismiss(t.id)} aria-label="Kapat" className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded text-text-muted hover:bg-surface-muted hover:text-text-primary">
                <X aria-hidden className="h-4 w-4" />
              </button>
            </div>
          );
        })}
      </div>
    </ToastContext.Provider>
  );
}
