"use client";

import { useEffect } from "react";
import { Button } from "@/components/ui/button";

/**
 * The thrown message is a Turkish sentence from lib/catalog/queries (e.g. "Ürünler
 * okunamadı: …"), but it can still carry a database detail, so only the digest is shown
 * and the full error goes to the console for the operator.
 */
export default function ProductsError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error("[catalog] sayfa hatası:", error);
  }, [error]);

  return (
    <div className="max-w-lg space-y-4 border-l-2 border-danger bg-panel px-4 py-5">
      <div>
        <h2 className="text-sm font-medium text-danger">Ürünler yüklenemedi</h2>
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
