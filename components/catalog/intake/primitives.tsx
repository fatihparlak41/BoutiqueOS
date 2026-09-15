"use client";

import { useEffect, useState } from "react";
import { Camera, X } from "lucide-react";
import { cn } from "@/lib/utils";

/**
 * Small pieces of the intake wizard: the step rail, the touch-sized chip, the photo
 * field with camera capture, the inline notices. All sized for a phone held in one
 * hand in the shop; desktop simply gets the same controls with more room.
 */

export const STEP_TITLES = ["Barkod", "Ürün", "Renk ve beden", "Varyantlar", "Kontrol"] as const;

export function StepRail({ step, mode }: { step: number; mode: "new" | "existing" }) {
  return (
    <ol className="flex items-center gap-1 text-2xs text-text-muted" aria-label="Adımlar">
      {STEP_TITLES.map((title, i) => {
        const n = i + 1;
        const skipped = mode === "existing" && n === 2;
        const state = n === step ? "current" : n < step ? "done" : "todo";
        return (
          <li key={title} className="flex items-center gap-1">
            <span
              aria-current={state === "current" ? "step" : undefined}
              className={cn(
                "inline-flex h-6 min-w-6 items-center justify-center rounded-full border px-1.5 font-medium",
                state === "current" && "border-accent bg-accent-muted text-accent",
                state === "done" && "border-border-strong bg-surface-muted text-text-secondary",
                state === "todo" && "border-border text-text-muted",
                skipped && "line-through opacity-60",
              )}
            >
              {n}
            </span>
            <span className={cn("hidden sm:inline", state === "current" && "text-text-primary")}>{title}</span>
            {n < STEP_TITLES.length ? <span aria-hidden className="mx-0.5 h-px w-3 bg-border sm:w-5" /> : null}
          </li>
        );
      })}
    </ol>
  );
}

export function Chip({
  on,
  onClick,
  children,
  disabled,
  title,
}: {
  on: boolean;
  onClick: () => void;
  children: React.ReactNode;
  disabled?: boolean;
  title?: string;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={on}
      disabled={disabled}
      title={title}
      className={cn(
        "min-h-11 rounded border px-3 py-1.5 text-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring sm:min-h-9 sm:text-xs",
        on ? "border-accent bg-accent-muted text-accent" : "border-border-strong bg-surface text-text-secondary hover:border-text-muted",
        disabled && "opacity-50",
      )}
    >
      {children}
    </button>
  );
}

export type Photo = { file: File; url: string };

/** Camera-first file field. The preview is a local object URL; nothing uploads until the review step. */
export function PhotoField({
  id,
  label,
  hint,
  photo,
  onChange,
  compact,
}: {
  id: string;
  label: string;
  hint?: string;
  photo: Photo | null;
  onChange: (photo: Photo | null) => void;
  compact?: boolean;
}) {
  const [url, setUrl] = useState<string | null>(photo?.url ?? null);
  useEffect(() => setUrl(photo?.url ?? null), [photo]);

  return (
    <div className={cn("space-y-1.5", compact && "flex items-center gap-3 space-y-0")}>
      {!compact ? <span className="block text-xs font-medium text-text-secondary">{label}</span> : null}
      <div className="flex items-center gap-3">
        <label
          htmlFor={id}
          className={cn(
            "flex cursor-pointer items-center justify-center overflow-hidden rounded border border-dashed border-border-strong bg-surface-muted/40 text-text-muted",
            compact ? "h-14 w-14" : "h-28 w-28",
            url && "border-solid",
          )}
        >
          {url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={url} alt={label} className="h-full w-full object-cover" />
          ) : (
            <Camera aria-hidden className={cn("stroke-[1.5]", compact ? "h-4 w-4" : "h-6 w-6")} />
          )}
          <span className="sr-only">{label}</span>
        </label>
        <div className="min-w-0 space-y-1">
          {compact ? <span className="block text-xs text-text-secondary">{label}</span> : null}
          <input
            id={id}
            type="file"
            accept="image/jpeg,image/png,image/webp"
            capture="environment"
            className="sr-only"
            onChange={(e) => {
              const file = e.target.files?.[0] ?? null;
              if (photo?.url) URL.revokeObjectURL(photo.url);
              onChange(file ? { file, url: URL.createObjectURL(file) } : null);
              e.target.value = "";
            }}
          />
          <label htmlFor={id} className="inline-flex min-h-11 cursor-pointer items-center rounded border border-border-strong bg-surface px-3 text-xs font-medium text-text-primary hover:bg-surface-muted sm:min-h-8">
            {photo ? "Yeniden çek" : "Fotoğraf çek"}
          </label>
          {photo ? (
            <button
              type="button"
              onClick={() => {
                URL.revokeObjectURL(photo.url);
                onChange(null);
              }}
              className="ml-2 inline-flex min-h-11 items-center gap-1 text-xs text-text-muted hover:text-text-primary sm:min-h-8"
            >
              <X aria-hidden className="h-3.5 w-3.5" /> Kaldır
            </button>
          ) : null}
          {hint && !photo ? <p className="text-2xs text-text-muted">{hint}</p> : null}
          {photo ? <p className="text-2xs text-text-muted" data-numeric>{photo.file.size < 1024 ? "<1" : (photo.file.size / 1024).toFixed(0)} KB</p> : null}
        </div>
      </div>
    </div>
  );
}

export function Notice({ tone, children }: { tone: "danger" | "warning" | "success" | "info"; children: React.ReactNode }) {
  return (
    <div
      role={tone === "danger" ? "alert" : "status"}
      className={cn(
        "rounded border px-3 py-2.5 text-sm",
        tone === "danger" && "border-danger/30 bg-danger-muted/50 text-danger",
        tone === "warning" && "border-warning/30 bg-warning-muted text-text-primary",
        tone === "success" && "border-success/25 bg-success-muted text-success",
        tone === "info" && "border-border bg-surface-muted/50 text-text-secondary",
      )}
    >
      {children}
    </div>
  );
}

export function Field({ label, htmlFor, hint, children }: { label: string; htmlFor: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1.5">
      <label htmlFor={htmlFor} className="block text-xs font-medium text-text-secondary">
        {label}
      </label>
      {children}
      {hint ? <p className="text-2xs text-text-muted">{hint}</p> : null}
    </div>
  );
}
