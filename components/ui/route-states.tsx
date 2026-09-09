"use client";

import { useEffect } from "react";
import { Button } from "@/components/ui/button";

/**
 * Shared loading and error surfaces for the Phase 3 route segments, so each segment's
 * loading.tsx / error.tsx stays a one-liner instead of six near-identical copies.
 */

export function RouteSkeleton({ title, rows = 5 }: { title: string; rows?: number }) {
  return (
    <div className="space-y-6" aria-busy="true" aria-live="polite">
      <span className="sr-only">{title} yükleniyor…</span>
      <div className="h-6 w-40 animate-pulse rounded bg-panel" />
      <div className="h-16 border-y border-line" />
      <div className="space-y-2">
        {Array.from({ length: rows }, (_, i) => (
          <div key={i} className="h-10 animate-pulse rounded bg-panel/70" />
        ))}
      </div>
    </div>
  );
}

/**
 * The thrown message is a Turkish sentence from the query layer, but it can still carry a
 * database detail, so only the digest is shown and the full error goes to the console.
 */
export function RouteError({
  title,
  error,
  reset,
}: {
  title: string;
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error(`[${title}] sayfa hatası:`, error);
  }, [title, error]);

  return (
    <div className="max-w-lg space-y-4 border-l-2 border-danger bg-panel px-4 py-5">
      <div>
        <h2 className="text-sm font-medium text-danger">{title} yüklenemedi</h2>
        <p className="mt-1 text-xs leading-relaxed text-ink-70">
          Bağlantı ya da yetki kaynaklı geçici bir sorun olabilir. Tekrar deneyin; sorun sürerse
          oturumu kapatıp yeniden girin.
        </p>
      </div>
      {error.digest ? (
        <p className="text-2xs text-muted" data-numeric>
          Hata kodu: {error.digest}
        </p>
      ) : null}
      <Button type="button" size="sm" variant="outline" onClick={reset}>
        Tekrar dene
      </Button>
    </div>
  );
}
