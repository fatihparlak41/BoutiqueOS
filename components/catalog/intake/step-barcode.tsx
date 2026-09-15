"use client";

import { useState } from "react";
import Link from "next/link";
import { ScanLine, Search } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { PRODUCT_STATUS_LABELS, VARIANT_STATUS_LABELS } from "@/lib/catalog/model";
import type { BarcodeHit } from "@/lib/catalog/queries";
import type { ProductSummary } from "@/lib/catalog/intake";
import { lookupBarcodeAction, searchProductsAction } from "@/app/app/urunler/katalog-ekle/actions";
import { Notice } from "./primitives";

/**
 * Step 1. A handheld scanner or a phone's scanner keyboard "types" the code and sends
 * Enter, so the field is a plain text input and Enter submits. A known code is a hard
 * stop: the existing variant is shown and nothing new can be created with it. An
 * unknown code travels to the matrix as the first variant's barcode. No label at all is
 * also a valid answer.
 */
export function StepBarcode({
  busy,
  onNew,
  onExisting,
  onError,
}: {
  busy: boolean;
  onNew: (code: string) => void;
  onExisting: (productId: string) => void;
  onError: (message: string | null) => void;
}) {
  const [code, setCode] = useState("");
  const [checked, setChecked] = useState<{ code: string; hit: BarcodeHit | null } | null>(null);
  const [looking, setLooking] = useState(false);

  const [term, setTerm] = useState("");
  const [results, setResults] = useState<ProductSummary[] | null>(null);
  const [searching, setSearching] = useState(false);

  async function lookup() {
    const trimmed = code.trim();
    onError(null);
    if (!trimmed) return;
    setLooking(true);
    const res = await lookupBarcodeAction(trimmed);
    setLooking(false);
    if (!res.ok) return onError(res.error);
    setChecked({ code: trimmed, hit: res.data });
  }

  async function search() {
    onError(null);
    setSearching(true);
    const res = await searchProductsAction(term);
    setSearching(false);
    if (!res.ok) return onError(res.error);
    setResults(res.data);
  }

  return (
    <div className="space-y-8">
      <section className="space-y-3">
        <h2 className="text-base font-medium">Etiketteki barkodu okutun</h2>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void lookup();
          }}
          className="flex items-center gap-2"
        >
          <label htmlFor="intake-barcode" className="sr-only">Barkod</label>
          <div className="relative w-full">
            <ScanLine aria-hidden className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 stroke-[1.5] text-text-muted" />
            <Input
              id="intake-barcode"
              value={code}
              onChange={(e) => {
                setCode(e.target.value);
                setChecked(null);
              }}
              placeholder="Okutun ya da yazın"
              className="h-12 pl-9 font-mono text-base sm:h-11"
              inputMode="text"
              autoComplete="off"
              autoCapitalize="off"
              spellCheck={false}
              autoFocus
              enterKeyHint="search"
            />
          </div>
          <Button type="submit" size="lg" disabled={looking || busy || !code.trim()}>
            {looking ? "…" : "Kontrol"}
          </Button>
        </form>

        {checked ? (
          checked.hit ? (
            <div className="space-y-3">
              <Notice tone="danger">
                <span data-numeric>{checked.code}</span> zaten kayıtlı. Bu barkodla yeni ürün oluşturulamaz.
              </Notice>
              <div className="rounded border border-border bg-surface p-4">
                <p className="text-sm font-medium">{checked.hit.product_name}</p>
                <p className="mt-1 flex flex-wrap items-center gap-2 text-xs text-text-secondary">
                  <span data-numeric>{checked.hit.sku}</span>
                  <Badge tone={checked.hit.variant_status === "active" ? "success" : "quiet"}>{VARIANT_STATUS_LABELS[checked.hit.variant_status]}</Badge>
                  <span className="text-2xs text-text-muted">{checked.hit.matched_by === "barcode" ? "barkodla eşleşti" : "SKU ile eşleşti"}</span>
                </p>
                <div className="mt-3 flex flex-wrap gap-2">
                  <Button variant="outline" size="sm" onClick={() => onExisting(checked.hit!.product_id)} disabled={busy}>
                    Bu ürüne varyant ekle
                  </Button>
                  <Link href={`/app/urunler/${checked.hit.product_id}`}>
                    <Button variant="ghost" size="sm">Ürün sayfası</Button>
                  </Link>
                </div>
              </div>
            </div>
          ) : (
            <div className="space-y-3">
              <Notice tone="success">
                <span data-numeric>{checked.code}</span> bu işletmede kayıtlı değil; yeni ürünün ilk varyantına yazılacak.
              </Notice>
              <Button onClick={() => onNew(checked.code)} disabled={busy} size="lg" className="w-full sm:w-auto">
                Yeni ürün olarak devam
              </Button>
            </div>
          )
        ) : null}
      </section>

      <section className="space-y-2 border-t border-border pt-5">
        <h2 className="text-sm font-medium">Etikette barkod yok</h2>
        <p className="text-xs text-text-muted">Barkodsuz ürün de eklenebilir; barkod sonradan etiketten girilir ya da üretilir.</p>
        <Button variant="outline" onClick={() => onNew("")} disabled={busy} className="w-full sm:w-auto">
          Barkodsuz yeni ürün
        </Button>
      </section>

      <section className="space-y-3 border-t border-border pt-5">
        <h2 className="text-sm font-medium">Mevcut bir modele varyant ekle</h2>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void search();
          }}
          className="flex items-center gap-2"
        >
          <label htmlFor="intake-search" className="sr-only">Ürün ara</label>
          <div className="relative w-full">
            <Search aria-hidden className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 stroke-[1.5] text-text-muted" />
            <Input id="intake-search" value={term} onChange={(e) => setTerm(e.target.value)} placeholder="Ürün adı, model kodu veya SKU ön eki" className="pl-9" autoComplete="off" />
          </div>
          <Button type="submit" variant="outline" disabled={searching || term.trim().length < 2}>
            {searching ? "…" : "Ara"}
          </Button>
        </form>
        {results ? (
          results.length === 0 ? (
            <p className="text-xs text-text-muted">Eşleşen ürün yok.</p>
          ) : (
            <ul className="divide-y divide-border border-y border-border">
              {results.map((p) => (
                <li key={p.id} className="flex items-center justify-between gap-3 py-2.5">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium">{p.name}</p>
                    <p className="flex flex-wrap gap-x-2 text-2xs text-text-muted">
                      {p.style_code ? <span data-numeric>{p.style_code}</span> : null}
                      <span data-numeric>{p.sku_prefix}</span>
                      <span>{p.variant_count} varyant</span>
                      <span>{PRODUCT_STATUS_LABELS[p.status]}</span>
                    </p>
                  </div>
                  <Button size="sm" variant="outline" onClick={() => onExisting(p.id)} disabled={busy}>
                    Seç
                  </Button>
                </li>
              ))}
            </ul>
          )
        ) : null}
      </section>
    </div>
  );
}
