"use client";

import { useEffect } from "react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";

/**
 * Shared loading and error surfaces for the route segments, so each segment's
 * loading.tsx / error.tsx stays a one-liner instead of near-identical copies.
 */

export function RouteSkeleton({ title, rows = 5 }: { title: string; rows?: number }) {
  return (
    <div className="space-y-8" aria-busy="true" aria-live="polite">
      <span className="sr-only">{title} yükleniyor…</span>
      <div className="space-y-2">
        <Skeleton className="h-6 w-40" />
        <Skeleton className="h-3.5 w-72 max-w-full" />
      </div>
      <div className="h-px bg-border" />
      <div className="space-y-2">
        {Array.from({ length: rows }, (_, i) => (
          <Skeleton key={i} className="h-10 opacity-70" />
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
    <div className="max-w-lg space-y-4 rounded border border-danger/30 bg-danger-muted/50 px-5 py-5">
      <div>
        <h2 className="text-sm font-medium text-danger">{title} yüklenemedi</h2>
        <p className="mt-1 text-xs leading-relaxed text-text-secondary">
          Bağlantı ya da yetki kaynaklı geçici bir sorun olabilir. Tekrar deneyin; sorun sürerse
          oturumu kapatıp yeniden girin.
        </p>
      </div>
      {error.digest ? (
        <p className="text-2xs text-text-muted" data-numeric>
          Hata kodu: {error.digest}
        </p>
      ) : null}
      <Button type="button" size="sm" variant="outline" onClick={reset}>
        Tekrar dene
      </Button>
    </div>
  );
}
