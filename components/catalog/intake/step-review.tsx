"use client";

import { ColorSwatch } from "@/components/catalog/color-swatch";
import type { NamedRef, ProductDetail } from "@/lib/catalog/model";
import { formatPrice, parseMoney } from "@/lib/catalog/format";
import type { IntakeCombo, IntakeIdentity } from "@/lib/catalog/intake";
import { Notice, type Photo } from "./primitives";

/**
 * Step 5. Everything that is about to be written, nothing that is not: no quantity, no
 * cost, no receipt. The save button lives in the wizard's sticky bar.
 */
export function StepReview({
  mode,
  existing,
  identity,
  category,
  brand,
  combos,
  mainPhoto,
  labelPhoto,
  colorPhotos,
  progress,
}: {
  mode: "new" | "existing";
  existing: ProductDetail | null;
  identity: IntakeIdentity;
  category: NamedRef | null;
  brand: NamedRef | null;
  combos: IntakeCombo[];
  mainPhoto: Photo | null;
  labelPhoto: Photo | null;
  colorPhotos: Record<string, Photo>;
  progress: { phase: "product" | "images" | "done"; imageIndex: number; imageTotal: number } | null;
}) {
  const colours = new Set(combos.flatMap((c) => c.values.filter((v) => v.option_kind === "color").map((v) => v.value)));
  const sizes = new Set(combos.flatMap((c) => c.values.filter((v) => v.option_kind === "size").map((v) => v.value)));
  const barcodes = combos.reduce((n, c) => n + c.barcodes.filter((b) => b.trim()).length, 0);
  const photoCount = (mainPhoto ? 1 : 0) + (labelPhoto ? 1 : 0) + Object.keys(colorPhotos).length;
  const price = identity.price.trim() ? parseMoney(identity.price) : null;

  const row = (label: string, value: React.ReactNode) => (
    <div className="flex justify-between gap-6 py-2">
      <dt className="text-text-muted">{label}</dt>
      <dd className="text-right">{value}</dd>
    </div>
  );

  return (
    <div className="space-y-6">
      {progress && progress.phase !== "done" ? (
        <Notice tone="info">
          {progress.phase === "product" ? "Ürün ve varyantlar yazılıyor…" : `Görsel ${progress.imageIndex}/${progress.imageTotal} yükleniyor…`}
        </Notice>
      ) : null}

      <section>
        <h2 className="text-base font-medium">{mode === "existing" ? existing?.name : identity.name}</h2>
        <dl className="mt-2 divide-y divide-border border-y border-border text-sm">
          {mode === "existing" && existing ? (
            <>
              {row("Ürün", <span className="text-text-muted">mevcut · {existing.variants.filter((v) => v.status === "active").length} aktif varyant</span>)}
              {row("SKU ön eki", <span data-numeric>{existing.sku_prefix}</span>)}
            </>
          ) : (
            <>
              {row("Model kodu", identity.style_code.trim() ? <span data-numeric>{identity.style_code}</span> : <span className="text-text-muted">—</span>)}
              {row("SKU ön eki", <span data-numeric>{identity.sku_prefix}</span>)}
              {row("Kategori", category ? category.name : <span className="text-text-muted">seçilmedi</span>)}
              {row("Marka", brand ? brand.name : <span className="text-text-muted">—</span>)}
              {row("Satış fiyatı", price !== null ? <span data-numeric>{formatPrice(price)}</span> : <span className="text-text-muted">girilmedi</span>)}
            </>
          )}
          {row("Renkler", colours.size > 0 ? [...colours].join(", ") : <span className="text-text-muted">—</span>)}
          {row("Bedenler", sizes.size > 0 ? [...sizes].join(", ") : <span className="text-text-muted">—</span>)}
          {row("Görseller", photoCount > 0 ? `${photoCount} fotoğraf` : <span className="text-text-muted">yok</span>)}
          {row("Stok", <span className="text-text-muted">bu akışta girilmez</span>)}
        </dl>
      </section>

      <section>
        <h3 className="text-sm font-medium">
          Eklenecek varyantlar <span className="ml-1 text-xs font-normal text-text-muted" data-numeric>{combos.length} varyant · {barcodes} barkod</span>
        </h3>
        <ul className="mt-2 divide-y divide-border border-y border-border text-sm">
          {combos.map((c) => (
            <li key={c.key} className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 py-2">
              <span className="flex flex-wrap items-center gap-x-2">
                {c.values.length === 0 ? "Tek varyant" : c.values.map((v) => (v.option_kind === "color" ? <ColorSwatch key={v.value_id} hex={v.color_hex} label={v.value} /> : <span key={v.value_id}>{v.value}</span>))}
              </span>
              <span className="text-2xs text-text-muted" data-numeric>
                {c.sku}
                {c.barcodes.filter((b) => b.trim()).length > 0 ? ` · ${c.barcodes.filter((b) => b.trim()).join(", ")}` : " · barkod yok"}
              </span>
            </li>
          ))}
        </ul>
      </section>

      {(mainPhoto || labelPhoto || Object.keys(colorPhotos).length > 0) ? (
        <section className="flex flex-wrap gap-3">
          {[
            mainPhoto ? { key: "main", label: "Ürün", photo: mainPhoto } : null,
            labelPhoto ? { key: "label", label: "Etiket", photo: labelPhoto } : null,
            ...Object.entries(colorPhotos).map(([id, photo]) => ({ key: id, label: combos.flatMap((c) => c.values).find((v) => v.value_id === id)?.value ?? "Renk", photo })),
          ]
            .filter((x): x is { key: string; label: string; photo: Photo } => !!x)
            .map((x) => (
              <figure key={x.key} className="w-24 text-center">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={x.photo.url} alt={x.label} className="h-24 w-24 rounded border border-border object-cover" />
                <figcaption className="mt-1 truncate text-2xs text-text-muted">{x.label}</figcaption>
              </figure>
            ))}
        </section>
      ) : null}

      <p className="text-2xs text-text-muted">
        Kayıt tek işlemde yapılır: ürün, varyantlar ve barkodlar birlikte yazılır; bir barkod çakışırsa hiçbiri kaydedilmez. Fotoğraflar sonra yüklenir.
      </p>
    </div>
  );
}
