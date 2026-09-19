"use client";

import { AlertCircle, ImageOff } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ColorSwatch } from "@/components/catalog/color-swatch";
import type { Photo } from "@/components/ui/photo-field";
import type { CategoryRef, NamedRef } from "@/lib/catalog/model";
import { formatPrice, parseMoney } from "@/lib/catalog/format";
import type { IntakeCombo, IntakeIdentity } from "@/lib/catalog/intake";
import type { Step } from "./primitives";
import { Notice } from "./primitives";

/**
 * Step 4 — the product as it will exist, at a glance: photo, name, category, price,
 * the colours and sizes, how many pieces that makes and how many carry a barcode. What
 * is missing is a row with a "Düzelt" that jumps back to the right step. Nothing
 * internal (SKU, model fields, image roles) is listed. The save button lives in the
 * wizard's sticky bar.
 */
export function StepReview({
  identity,
  category,
  brand,
  combos,
  mainPhoto,
  colorPhotos,
  labelPhoto,
  progress,
  onFix,
}: {
  identity: IntakeIdentity;
  category: CategoryRef | null;
  brand: NamedRef | null;
  combos: IntakeCombo[];
  mainPhoto: Photo | null;
  colorPhotos: Record<string, Photo>;
  labelPhoto: Photo | null;
  progress: { phase: "product" | "images" | "done"; imageIndex: number; imageTotal: number } | null;
  onFix: (step: Step) => void;
}) {
  const colours = [...new Map(combos.flatMap((c) => c.values.filter((v) => v.option_kind === "color").map((v) => [v.value_id, v]))).values()];
  const sizes = [...new Set(combos.flatMap((c) => c.values.filter((v) => v.option_kind === "size").map((v) => v.value)))];
  const barcodes = combos.reduce((n, c) => n + c.barcodes.filter((b) => b.trim()).length, 0);
  const extraPhotos = Object.keys(colorPhotos).length + (labelPhoto ? 1 : 0);
  const price = identity.price.trim() ? parseMoney(identity.price) : null;
  const single = combos.length === 1 && combos[0].values.length === 0;

  const missing: Array<{ key: string; text: string; step: Step }> = [];
  if (!mainPhoto) missing.push({ key: "photo", text: "Fotoğraf eklenmedi", step: 1 });
  if (!category) missing.push({ key: "category", text: "Kategori seçilmedi", step: 1 });
  if (price === null) missing.push({ key: "price", text: "Satış fiyatı girilmedi", step: 1 });
  if (barcodes === 0) missing.push({ key: "barcode", text: "Barkod okutulmadı", step: 3 });

  return (
    <div className="space-y-6">
      {progress && progress.phase !== "done" ? (
        <Notice tone="info">
          {progress.phase === "product" ? "Ürün kaydediliyor…" : `Fotoğraf ${progress.imageIndex}/${progress.imageTotal} yükleniyor…`}
        </Notice>
      ) : null}

      <section className="flex gap-4 rounded border border-border bg-surface p-4" data-testid="review-card">
        <div className="h-28 w-28 shrink-0 overflow-hidden rounded border border-border bg-surface-muted sm:h-36 sm:w-36">
          {mainPhoto ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={mainPhoto.url} alt={identity.name} className="h-full w-full object-cover" />
          ) : (
            <span className="flex h-full w-full items-center justify-center text-text-muted"><ImageOff aria-hidden className="h-6 w-6 stroke-[1.5]" /></span>
          )}
        </div>
        <div className="min-w-0 flex-1 space-y-1">
          <h2 className="text-lg font-medium leading-tight text-text-primary">{identity.name}</h2>
          <p className="text-sm text-text-secondary">{category ? category.name : <span className="text-text-muted">Kategori yok</span>}{brand ? ` · ${brand.name}` : ""}</p>
          <p className="text-lg font-medium" data-numeric>{price !== null ? formatPrice(price) : <span className="text-sm font-normal text-text-muted">Fiyat girilmedi</span>}</p>
          {identity.style_code.trim() ? <p className="text-xs text-text-muted" data-numeric>Model {identity.style_code}</p> : null}
        </div>
      </section>

      <dl className="grid gap-4 sm:grid-cols-2">
        <div>
          <dt className="text-xs font-medium text-text-secondary">Renkler</dt>
          <dd className="mt-1 flex flex-wrap gap-2 text-sm">
            {colours.length > 0 ? colours.map((v) => <span key={v.value_id} className="inline-flex items-center rounded border border-border bg-surface px-2 py-1"><ColorSwatch hex={v.color_hex} label={v.value} /></span>) : <span className="text-text-muted">—</span>}
          </dd>
        </div>
        <div>
          <dt className="text-xs font-medium text-text-secondary">Bedenler</dt>
          <dd className="mt-1 flex flex-wrap gap-2 text-sm">
            {sizes.length > 0 ? sizes.map((s) => <span key={s} className="inline-flex items-center rounded border border-border bg-surface px-2 py-1">{s}</span>) : <span className="text-text-muted">—</span>}
          </dd>
        </div>
      </dl>

      <p className="text-sm text-text-primary" data-testid="review-summary">
        <span className="font-medium" data-numeric>{single ? "Tek seçenekli ürün" : `${combos.length} ürün seçeneği`}</span>
        <span className="text-text-muted"> · </span>
        <span data-numeric>{barcodes} barkod eklendi</span>
        {extraPhotos > 0 ? <><span className="text-text-muted"> · </span><span data-numeric>{extraPhotos} ek fotoğraf</span></> : null}
      </p>

      {!single ? (
        <ul className="divide-y divide-border border-y border-border text-sm">
          {combos.map((c) => (
            <li key={c.key} className="flex items-center justify-between gap-3 py-2">
              <span className="flex flex-wrap items-center gap-x-2">
                {c.values.map((v, i) => (
                  <span key={v.value_id} className="flex items-center gap-2">
                    {i > 0 ? <span className="text-text-muted">·</span> : null}
                    {v.option_kind === "color" ? <ColorSwatch hex={v.color_hex} label={v.value} /> : <span>{v.value}</span>}
                  </span>
                ))}
              </span>
              <span className="text-2xs text-text-muted" data-numeric>
                {c.barcodes.filter((b) => b.trim()).length > 0 ? c.barcodes.filter((b) => b.trim()).join(", ") : "barkod yok"}
              </span>
            </li>
          ))}
        </ul>
      ) : null}

      {missing.length > 0 ? (
        <ul className="space-y-2" data-testid="review-missing">
          {missing.map((m) => (
            <li key={m.key} className="flex items-center justify-between gap-3 rounded border border-warning/40 bg-warning-muted/60 px-3 py-2 text-sm">
              <span className="flex items-center gap-2"><AlertCircle aria-hidden className="h-4 w-4 shrink-0 text-warning" />{m.text}</span>
              <Button type="button" size="sm" variant="outline" onClick={() => onFix(m.step)}>Düzelt</Button>
            </li>
          ))}
          <li className="text-xs text-text-muted">Bunlar zorunlu değil; ürün sayfasından sonra da tamamlanabilir.</li>
        </ul>
      ) : null}
    </div>
  );
}
