"use client";

import * as React from "react";
import { Camera, ImagePlus, X } from "lucide-react";
import { cn } from "@/lib/utils";

export type Photo = { file: File; url: string };

/**
 * One photo, chosen once. The whole field is the drop / tap target: on a phone the
 * file picker offers the camera and the gallery (`capture` forces the rear camera when
 * the shot must be taken on the spot, e.g. a label). The preview is a local object URL;
 * nothing uploads here — the caller uploads when it decides to. Replace and remove are
 * explicit buttons over the preview.
 */
export function PhotoField({
  id,
  label,
  hint,
  photo,
  onChange,
  camera = false,
  size = "lg",
  className,
}: {
  id: string;
  label: string;
  hint?: string;
  photo: Photo | null;
  onChange: (photo: Photo | null) => void;
  camera?: boolean;
  /** lg: the hero field of a form (full width, ~11rem tall). sm: a compact square tile. */
  size?: "lg" | "sm";
  className?: string;
}) {
  const inputRef = React.useRef<HTMLInputElement>(null);
  const [dragging, setDragging] = React.useState(false);

  function accept(file: File | null) {
    if (photo?.url) URL.revokeObjectURL(photo.url);
    onChange(file ? { file, url: URL.createObjectURL(file) } : null);
  }

  const Icon = camera ? Camera : ImagePlus;

  return (
    <div className={cn("space-y-1.5", className)}>
      {size === "lg" ? <span className="block text-xs font-medium text-text-secondary">{label}</span> : null}
      <input
        ref={inputRef}
        id={id}
        type="file"
        accept="image/jpeg,image/png,image/webp"
        capture={camera ? "environment" : undefined}
        className="sr-only"
        onChange={(e) => {
          accept(e.target.files?.[0] ?? null);
          e.target.value = "";
        }}
      />
      {photo ? (
        <div className={cn("relative overflow-hidden rounded border border-border bg-surface-muted", size === "lg" ? "h-56 w-full sm:h-64" : "h-20 w-20")}>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={photo.url} alt={label} className="h-full w-full object-cover" />
          <div className={cn("absolute inset-x-0 bottom-0 flex items-center justify-between gap-2 bg-black/45 px-2 py-1.5 text-white", size === "sm" && "px-1 py-1")}>
            {size === "lg" ? <span className="truncate text-xs">{label}</span> : null}
            <span className="ml-auto flex items-center gap-1">
              <button type="button" onClick={() => inputRef.current?.click()} className="inline-flex min-h-8 items-center rounded px-2 text-xs font-medium hover:bg-white/15">
                Değiştir
              </button>
              <button type="button" onClick={() => accept(null)} aria-label={`${label} kaldır`} className="inline-flex h-8 w-8 items-center justify-center rounded hover:bg-white/15">
                <X aria-hidden className="h-4 w-4" />
              </button>
            </span>
          </div>
        </div>
      ) : (
        <button
          type="button"
          onClick={() => inputRef.current?.click()}
          onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
          onDragLeave={() => setDragging(false)}
          onDrop={(e) => {
            e.preventDefault();
            setDragging(false);
            const file = e.dataTransfer.files?.[0];
            if (file && file.type.startsWith("image/")) accept(file);
          }}
          aria-label={label}
          className={cn(
            "flex w-full flex-col items-center justify-center gap-2 rounded border border-dashed border-border-strong bg-surface-muted/40 text-text-secondary transition-colors",
            "hover:border-accent hover:bg-accent-muted/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
            dragging && "border-accent bg-accent-muted/40",
            size === "lg" ? "min-h-40 px-4 py-6 sm:min-h-44" : "h-20 w-20 gap-1 p-1",
          )}
        >
          <Icon aria-hidden className={cn("stroke-[1.5] text-text-muted", size === "lg" ? "h-7 w-7" : "h-5 w-5")} />
          {size === "lg" ? (
            <>
              <span className="text-sm font-medium text-text-primary">{camera ? "Fotoğraf çek" : "Fotoğraf çek veya yükle"}</span>
              {hint ? <span className="text-2xs text-text-muted">{hint}</span> : null}
            </>
          ) : (
            <span className="text-2xs">{label}</span>
          )}
        </button>
      )}
    </div>
  );
}
