"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { ChevronDown } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Combobox, type ComboboxItem } from "@/components/ui/combobox";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { PhotoField, type Photo } from "@/components/ui/photo-field";
import { categoryPath, type CategoryRef, type NamedRef } from "@/lib/catalog/model";
import type { DuplicateReport, IntakeIdentity, ProductSummary } from "@/lib/catalog/intake";
import { createCategoryAction } from "@/app/app/urunler/katalog-ekle/actions";
import { Field, Notice } from "./primitives";
import { cn } from "@/lib/utils";

/**
 * Step 1 — the product as a person sees it: a photo, a name, where it belongs, what it
 * sells for. Everything else (model code, brand, the label photo) waits under "Diğer
 * seçenekler". The SKU prefix is derived and never shown here.
 *
 * Categories: an existing one is chosen from a searchable, hierarchical list. A new one
 * is created only after typing it, choosing "+ Yeni kategori oluştur" and confirming in
 * a dialog — never from a tap on a suggestion.
 */
export function StepProduct({
  identity,
  onChange,
  categories,
  onCategoryCreated,
  brands,
  mainPhoto,
  labelPhoto,
  onMainPhoto,
  onLabelPhoto,
  duplicates,
  onContinueAsNew,
}: {
  identity: IntakeIdentity;
  onChange: (patch: Partial<IntakeIdentity>) => void;
  categories: CategoryRef[];
  onCategoryCreated: (category: CategoryRef) => void;
  brands: NamedRef[];
  mainPhoto: Photo | null;
  labelPhoto: Photo | null;
  onMainPhoto: (p: Photo | null) => void;
  onLabelPhoto: (p: Photo | null) => void;
  duplicates: DuplicateReport | null;
  onContinueAsNew: () => void;
}) {
  const [more, setMore] = useState(Boolean(identity.style_code || identity.brand_id || labelPhoto));
  const [pendingCategory, setPendingCategory] = useState<string | null>(null);
  const [categoryBusy, setCategoryBusy] = useState(false);
  const [categoryError, setCategoryError] = useState<string | null>(null);
  const dupRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (duplicates) dupRef.current?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }, [duplicates]);

  const items: ComboboxItem[] = categories
    .map((c) => {
      const p = categoryPath(c, categories);
      return { id: c.id, label: p.label, group: p.group };
    })
    .sort((a, b) => `${a.group ?? ""} ${a.label}`.localeCompare(`${b.group ?? ""} ${b.label}`, "tr"));

  async function confirmCreate() {
    if (!pendingCategory) return;
    setCategoryError(null);
    setCategoryBusy(true);
    const res = await createCategoryAction(pendingCategory);
    setCategoryBusy(false);
    if (!res.ok) {
      setPendingCategory(null);
      return setCategoryError(res.error);
    }
    onCategoryCreated(res.data);
    setPendingCategory(null);
  }

  const dupList = (items: ProductSummary[]) => (
    <ul className="mt-2 divide-y divide-border border-y border-border">
      {items.map((p) => (
        <li key={p.id} className="flex items-center justify-between gap-3 py-2">
          <div className="min-w-0">
            <p className="truncate text-sm font-medium text-text-primary">{p.name}</p>
            <p className="text-2xs text-text-muted">
              {p.category ? `${p.category.name} · ` : ""}
              {p.variant_count} seçenek{p.status !== "active" ? " · arşivde" : ""}
            </p>
          </div>
          <Link href={`/app/urunler/${p.id}`} className="shrink-0">
            <Button size="sm" variant="outline">Ürünü aç</Button>
          </Link>
        </li>
      ))}
    </ul>
  );

  return (
    <div className="space-y-6">
      <PhotoField id="intake-main-photo" label="Ürün fotoğrafı" hint="Ürünün tamamı görünsün; arka plan önemli değil." photo={mainPhoto} onChange={onMainPhoto} />

      <Field label="Ürün adı" htmlFor="intake-name" hint="Etiketteki ad ya da kısa bir tanım, örn. Keten Crop Bluz.">
        <Input id="intake-name" value={identity.name} onChange={(e) => onChange({ name: e.target.value })} maxLength={200} placeholder="Örn. Keten Crop Bluz" className="h-11 text-base sm:h-10 sm:text-sm" />
      </Field>

      <Field label="Kategori" htmlFor="intake-category">
        <Combobox
          id="intake-category"
          value={identity.category_id || null}
          items={items}
          onChange={(id) => onChange({ category_id: id ?? "" })}
          placeholder="Kategori seçin"
          searchPlaceholder="Kategori ara… (örn. Bluz)"
          createLabel="Yeni kategori oluştur"
          onCreate={(name) => setPendingCategory(name)}
          aria-label="Kategori"
        />
        {categoryError ? <p className="text-xs text-danger">{categoryError}</p> : null}
      </Field>

      <Field label="Satış fiyatı" htmlFor="intake-price" hint="Şimdi girmezsen sonra ürün sayfasından girebilirsin.">
        <div className="relative">
          <span aria-hidden className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-text-muted">₺</span>
          <Input id="intake-price" value={identity.price} onChange={(e) => onChange({ price: e.target.value })} inputMode="decimal" placeholder="0,00" className="h-11 pl-7 text-base sm:h-10 sm:text-sm" />
        </div>
      </Field>

      <div className="border-t border-border pt-4">
        <button
          type="button"
          onClick={() => setMore((v) => !v)}
          aria-expanded={more}
          className="flex min-h-11 w-full items-center justify-between text-sm font-medium text-text-secondary hover:text-text-primary sm:min-h-9"
        >
          Diğer seçenekler
          <ChevronDown aria-hidden className={cn("h-4 w-4 transition-transform", more && "rotate-180")} />
        </button>
        {more ? (
          <div className="mt-3 grid gap-4 sm:grid-cols-2">
            <Field label="Model / stil kodu" htmlFor="intake-style" optional hint="Etiketteki ya da tedarikçinin kodu.">
              <Input id="intake-style" value={identity.style_code} onChange={(e) => onChange({ style_code: e.target.value })} maxLength={64} spellCheck={false} autoCapitalize="characters" placeholder="Örn. SS26-041" className="h-11 sm:h-10" />
            </Field>
            <Field label="Marka" htmlFor="intake-brand" optional>
              <Select id="intake-brand" value={identity.brand_id} onChange={(e) => onChange({ brand_id: e.target.value })} className="h-11 sm:h-10">
                <option value="">Seçilmedi</option>
                {brands.map((b) => (
                  <option key={b.id} value={b.id}>{b.name}</option>
                ))}
              </Select>
            </Field>
            <div className="sm:col-span-2">
              <PhotoField id="intake-label-photo" label="Etiket fotoğrafı" hint="Barkod, model ve beden okunacak kadar yakın; yalnız mağaza içinde görünür." photo={labelPhoto} onChange={onLabelPhoto} camera />
            </div>
          </div>
        ) : null}
      </div>

      {duplicates ? (
        <div ref={dupRef} className="space-y-3 scroll-mb-28">
          {duplicates.style_matches.length > 0 ? (
            <Notice tone="warning">
              <p className="font-medium">Aynı model kodu zaten kayıtlı.</p>
              <p className="mt-0.5 text-xs text-text-secondary">Büyük olasılıkla aynı ürün. Yeni renk ya da beden ekleyeceksen ürün sayfasını aç.</p>
              {dupList(duplicates.style_matches)}
            </Notice>
          ) : null}
          {duplicates.name_matches.length > 0 ? (
            <Notice tone="info">
              <p className="font-medium text-text-primary">Benzer adlı bir ürün var.</p>
              {dupList(duplicates.name_matches)}
            </Notice>
          ) : null}
          <Button variant="outline" onClick={onContinueAsNew} className="w-full sm:w-auto">
            Yine de yeni ürün olarak devam et
          </Button>
        </div>
      ) : null}

      <ConfirmDialog
        open={pendingCategory !== null}
        onClose={() => setPendingCategory(null)}
        title={`"${pendingCategory ?? ""}" adlı yeni bir kategori oluşturulsun mu?`}
        description="Kategori mağazanın listesine eklenir ve sonraki ürünlerde de seçilebilir."
        confirmLabel="Kategoriyi oluştur"
        busy={categoryBusy}
        onConfirm={() => void confirmCreate()}
      />
    </div>
  );
}
