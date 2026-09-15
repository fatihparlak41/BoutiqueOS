"use client";

import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Badge } from "@/components/ui/badge";
import { PRODUCT_STATUS_LABELS, type NamedRef } from "@/lib/catalog/model";
import { CATEGORY_SUGGESTIONS, normalizeName, type DuplicateReport, type IntakeIdentity, type ProductSummary } from "@/lib/catalog/intake";
import { createCategoryAction } from "@/app/app/urunler/katalog-ekle/actions";
import { Field, Notice, PhotoField, type Photo } from "./primitives";

/**
 * Step 2. What the label says, not a marketing name: model name or code first, a short
 * description otherwise. Two photos: the garment and its label. The duplicate report
 * appears here when the server finds the same code or the same normalised name; the
 * person picks "use existing" or "continue as new". Nothing merges by itself.
 */
export function StepIdentity({
  identity,
  onChange,
  onPrefixEdit,
  categories,
  onCategoryCreated,
  brands,
  mainPhoto,
  labelPhoto,
  onMainPhoto,
  onLabelPhoto,
  duplicates,
  onUseExisting,
  onContinueAsNew,
  scannedCode,
}: {
  identity: IntakeIdentity;
  onChange: (patch: Partial<IntakeIdentity>) => void;
  onPrefixEdit: (value: string) => void;
  categories: NamedRef[];
  onCategoryCreated: (category: NamedRef) => void;
  brands: NamedRef[];
  mainPhoto: Photo | null;
  labelPhoto: Photo | null;
  onMainPhoto: (p: Photo | null) => void;
  onLabelPhoto: (p: Photo | null) => void;
  duplicates: DuplicateReport | null;
  onUseExisting: (product: ProductSummary) => void;
  onContinueAsNew: () => void;
  scannedCode: string;
}) {
  const [showPrefix, setShowPrefix] = useState(false);
  const [newCategory, setNewCategory] = useState("");
  const [categoryBusy, setCategoryBusy] = useState(false);
  const [categoryError, setCategoryError] = useState<string | null>(null);
  // The duplicate report appears below the photos; bring it into view so the decision is not missed.
  const dupRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (duplicates) dupRef.current?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }, [duplicates]);

  const have = new Set(categories.map((c) => normalizeName(c.name)));
  const suggestions = CATEGORY_SUGGESTIONS.filter((s) => !have.has(normalizeName(s)));

  async function addCategory(name: string) {
    setCategoryError(null);
    setCategoryBusy(true);
    const res = await createCategoryAction(name);
    setCategoryBusy(false);
    if (!res.ok) return setCategoryError(res.error);
    onCategoryCreated(res.data);
    setNewCategory("");
  }

  const dupList = (items: ProductSummary[]) => (
    <ul className="mt-2 divide-y divide-border border-y border-border">
      {items.map((p) => (
        <li key={p.id} className="flex items-center justify-between gap-3 py-2">
          <div className="min-w-0">
            <p className="truncate text-sm font-medium text-text-primary">{p.name}</p>
            <p className="flex flex-wrap gap-x-2 text-2xs text-text-muted">
              {p.style_code ? <span data-numeric>{p.style_code}</span> : null}
              <span data-numeric>{p.sku_prefix}</span>
              {p.category ? <span>{p.category.name}</span> : null}
              <span>{p.variant_count} varyant</span>
              <Badge tone={p.status === "active" ? "success" : "quiet"}>{PRODUCT_STATUS_LABELS[p.status]}</Badge>
            </p>
          </div>
          <Button size="sm" variant="outline" onClick={() => onUseExisting(p)}>
            Mevcut ürünü kullan
          </Button>
        </li>
      ))}
    </ul>
  );

  return (
    <div className="space-y-6">
      {scannedCode ? (
        <p className="text-xs text-text-muted">
          Barkod <span data-numeric className="text-text-primary">{scannedCode}</span> ilk varyanta yazılacak.
        </p>
      ) : null}

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="sm:col-span-2">
          <Field label="Ürün adı" htmlFor="intake-name" hint="Etiketteki model adı; yoksa kısa ve fiziksel bir tanım (örn. Keten Crop Bluz). Pazarlama adı uydurmayın.">
            <Input id="intake-name" value={identity.name} onChange={(e) => onChange({ name: e.target.value })} maxLength={200} autoFocus placeholder="Etiketteki ad ya da kısa tanım" />
          </Field>
        </div>
        <Field label="Model / stil kodu" htmlFor="intake-style" hint="Etiket ya da tedarikçi kodu; boş bırakılabilir.">
          <Input id="intake-style" value={identity.style_code} onChange={(e) => onChange({ style_code: e.target.value })} maxLength={64} spellCheck={false} autoCapitalize="characters" placeholder="Örn. SS26-041" className="font-mono" />
        </Field>
        <Field label="Satış fiyatı" htmlFor="intake-price" hint="İsteğe bağlı; sonra ürün sayfasından girilebilir.">
          <Input id="intake-price" value={identity.price} onChange={(e) => onChange({ price: e.target.value })} inputMode="decimal" placeholder="0,00" />
        </Field>

        <Field label="Kategori" htmlFor="intake-category">
          <Select id="intake-category" value={identity.category_id} onChange={(e) => onChange({ category_id: e.target.value })}>
            <option value="">Seçilmedi</option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>{c.name}</option>
            ))}
          </Select>
          {suggestions.length > 0 ? (
            <div className="mt-2 flex flex-wrap gap-1.5">
              {suggestions.map((s) => (
                <button
                  key={s}
                  type="button"
                  disabled={categoryBusy}
                  onClick={() => addCategory(s)}
                  className="min-h-9 rounded-sm border border-dashed border-border-strong px-2 text-2xs text-text-secondary hover:border-text-muted sm:min-h-7"
                >
                  + {s}
                </button>
              ))}
            </div>
          ) : null}
          <div className="mt-2 flex items-center gap-2">
            <Input value={newCategory} onChange={(e) => setNewCategory(e.target.value)} placeholder="Başka bir kategori" maxLength={60} className="h-10 text-xs sm:h-9" aria-label="Yeni kategori adı" />
            <Button type="button" size="sm" variant="outline" disabled={categoryBusy || newCategory.trim().length < 2} onClick={() => addCategory(newCategory)}>
              Ekle
            </Button>
          </div>
          {categoryError ? <p className="mt-1 text-2xs text-danger">{categoryError}</p> : null}
        </Field>

        <Field label="Marka" htmlFor="intake-brand" hint="İsteğe bağlı.">
          <Select id="intake-brand" value={identity.brand_id} onChange={(e) => onChange({ brand_id: e.target.value })}>
            <option value="">Seçilmedi</option>
            {brands.map((b) => (
              <option key={b.id} value={b.id}>{b.name}</option>
            ))}
          </Select>
        </Field>
      </div>

      <div className="text-xs text-text-muted">
        SKU ön eki: <span data-numeric className="text-text-primary">{identity.sku_prefix || "—"}</span>{" "}
        <button type="button" className="underline underline-offset-4 hover:text-text-primary" onClick={() => setShowPrefix((v) => !v)}>
          {showPrefix ? "gizle" : "düzenle"}
        </button>
        {showPrefix ? (
          <Input value={identity.sku_prefix} onChange={(e) => onPrefixEdit(e.target.value)} maxLength={32} spellCheck={false} className="mt-2 font-mono" aria-label="SKU ön eki" />
        ) : null}
      </div>

      <div className="grid gap-5 border-t border-border pt-5 sm:grid-cols-2">
        <PhotoField id="intake-main-photo" label="Ürün fotoğrafı" hint="Ürünün tamamı görünsün; arka plan önemli değil." photo={mainPhoto} onChange={onMainPhoto} />
        <PhotoField id="intake-label-photo" label="Etiket fotoğrafı" hint="Barkod, model ve beden okunacak kadar yakın." photo={labelPhoto} onChange={onLabelPhoto} camera />
      </div>

      {duplicates ? (
        <div ref={dupRef} className="space-y-3 scroll-mb-28">
          {duplicates.style_matches.length > 0 ? (
            <Notice tone="warning">
              <p className="font-medium">Aynı model kodu zaten kayıtlı.</p>
              <p className="mt-0.5 text-xs text-text-secondary">Büyük olasılıkla aynı ürün. Yeni renk ya da beden ekliyorsanız mevcut ürünü kullanın.</p>
              {dupList(duplicates.style_matches)}
            </Notice>
          ) : null}
          {duplicates.name_matches.length > 0 ? (
            <Notice tone="info">
              <p className="font-medium text-text-primary">Benzer adlı ürün var.</p>
              {dupList(duplicates.name_matches)}
            </Notice>
          ) : null}
          <Button variant="outline" onClick={onContinueAsNew} className="w-full sm:w-auto">
            Yeni ürün olarak devam et
          </Button>
        </div>
      ) : null}
    </div>
  );
}
