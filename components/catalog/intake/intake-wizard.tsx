"use client";

import { useCallback, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { CheckCircle2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import type { Photo } from "@/components/ui/photo-field";
import type { CategoryRef, NamedRef, ProductOption } from "@/lib/catalog/model";
import {
  comboFingerprint,
  suggestComboSku,
  suggestPrefix,
  type DuplicateReport,
  type IntakeCombo,
  type IntakeIdentity,
  type IntakeValue,
  type KnownBarcode,
  type OnboardCombo,
  type OnboardResult,
} from "@/lib/catalog/intake";
import { checkDuplicatesAction, lookupBarcodeAction, onboardProductAction, uploadIntakeImageAction } from "@/app/app/urunler/katalog-ekle/actions";
import { Stepper, Notice, type Step } from "./primitives";
import { StepProduct } from "./step-product";
import { StepOptions } from "./step-options";
import { StepBarcodes } from "./step-barcodes";
import { StepReview } from "./step-review";

/**
 * Adding a garment, phone in hand — four steps in a shop's words:
 *
 *   1  Ürün          photo, name, category, price (model code, brand, label photo folded away)
 *   2  Renk & Beden  the colours and sizes on the shelf; "no options" is an explicit tick
 *   3  Barkod        optional: a barcode per colour × size, straight from the label
 *   4  Kontrol       the product at a glance, what is missing, one "Ürünü kaydet"
 *
 * Nothing is written before step 4. The save is one transaction for product + options +
 * barcodes (rpc_onboard_product, unchanged); photos upload afterwards, one by one, and a
 * failed photo never undoes the product. No quantity anywhere: stock is counted later.
 * Internal names (SKU, prefix, variant) are derived here and never shown.
 */

type SaveProgress = { phase: "product" | "images" | "done"; imageIndex: number; imageTotal: number; imageErrors: string[] };

const EMPTY_IDENTITY: IntakeIdentity = { name: "", style_code: "", sku_prefix: "", category_id: "", brand_id: "", price: "" };

export function IntakeWizard({
  initialOptions,
  initialCategories,
  brands,
}: {
  initialOptions: ProductOption[];
  initialCategories: CategoryRef[];
  brands: NamedRef[];
}) {
  const router = useRouter();
  const [step, setStep] = useState<Step>(1);
  const [options, setOptions] = useState<ProductOption[]>(initialOptions);
  const [categories, setCategories] = useState<CategoryRef[]>(initialCategories);

  const [identity, setIdentity] = useState<IntakeIdentity>(EMPTY_IDENTITY);
  const [mainPhoto, setMainPhoto] = useState<Photo | null>(null);
  const [labelPhoto, setLabelPhoto] = useState<Photo | null>(null);
  const [duplicates, setDuplicates] = useState<DuplicateReport | null>(null);
  const [duplicatesAccepted, setDuplicatesAccepted] = useState(false);

  const [selected, setSelected] = useState<Record<string, string[]>>({});
  const [noOptions, setNoOptions] = useState(false);

  const [disabled, setDisabled] = useState<Record<string, boolean>>({});
  const [barcodeEdits, setBarcodeEdits] = useState<Record<string, string[]>>({});
  const [colorPhotos, setColorPhotos] = useState<Record<string, Photo>>({});
  const [knownBarcodes, setKnownBarcodes] = useState<Record<string, KnownBarcode>>({});

  const [busy, setBusy] = useState(false);
  const submitting = useRef(false);
  const [error, setError] = useState<string | null>(null);
  const [progress, setProgress] = useState<SaveProgress | null>(null);
  const [result, setResult] = useState<OnboardResult | null>(null);

  const colorOption = options.find((o) => o.kind === "color") ?? null;
  const sizeOption = options.find((o) => o.kind === "size") ?? null;

  // ------------------------------------------------------------ derived

  const toValue = useCallback((option: ProductOption, valueId: string): IntakeValue | null => {
    const v = option.values.find((x) => x.id === valueId);
    return v ? { option_id: option.id, option_kind: option.kind, value_id: v.id, value: v.value, code: v.code, color_hex: v.color_hex, sort_order: v.sort_order } : null;
  }, []);

  const groups = useMemo(() => {
    const out: IntakeValue[][] = [];
    for (const option of [colorOption, sizeOption]) {
      if (!option) continue;
      const chosen = (selected[option.id] ?? []).map((id) => toValue(option, id)).filter((v): v is IntakeValue => !!v);
      chosen.sort((a, b) => a.sort_order - b.sort_order || a.value.localeCompare(b.value, "tr"));
      if (chosen.length > 0) out.push(chosen);
    }
    return out;
  }, [colorOption, sizeOption, selected, toValue]);

  const combos: IntakeCombo[] = useMemo(() => {
    if (groups.length === 0 && !noOptions) return [];
    const rows = groups.length === 0 ? [[] as IntakeValue[]] : groups.reduce<IntakeValue[][]>((acc, g) => acc.flatMap((row) => g.map((v) => [...row, v])), [[]]);
    return rows.map((values) => {
      const key = values.map((v) => v.value_id).join("+") || "single";
      return {
        key,
        values,
        // internal: derived from the name (or model code) and the values' short codes
        sku: suggestComboSku(identity.sku_prefix, values),
        barcodes: barcodeEdits[key] ?? [""],
        enabled: !disabled[key],
        exists: false,
      };
    });
  }, [groups, noOptions, barcodeEdits, identity.sku_prefix, disabled]);

  const payload: OnboardCombo[] = combos
    .filter((c) => c.enabled)
    .map((c) => ({ sku: c.sku, option_value_ids: c.values.map((v) => v.value_id), barcodes: c.barcodes.map((b) => b.trim()).filter(Boolean) }));

  void comboFingerprint; // kept in the vocabulary for the product page's matrix

  // ------------------------------------------------------------ step transitions

  function updateIdentity(patch: Partial<IntakeIdentity>) {
    setError(null);
    setIdentity((prev) => {
      const next = { ...prev, ...patch };
      if (patch.name !== undefined || patch.style_code !== undefined) next.sku_prefix = suggestPrefix(next.style_code, next.name);
      return next;
    });
    if (patch.name !== undefined || patch.style_code !== undefined) {
      setDuplicates(null);
      setDuplicatesAccepted(false);
    }
  }

  async function leaveProduct() {
    setError(null);
    if (identity.name.trim().length < 2) return setError("Ürün adı en az 2 karakter olmalı.");
    if (!duplicatesAccepted) {
      setBusy(true);
      const res = await checkDuplicatesAction({ name: identity.name, style_code: identity.style_code });
      setBusy(false);
      if (!res.ok) return setError(res.error);
      if (res.data.style_matches.length > 0 || res.data.name_matches.length > 0) {
        setDuplicates(res.data);
        return;
      }
    }
    setStep(2);
  }

  function leaveOptions() {
    setError(null);
    if (groups.length === 0 && !noOptions) return setError("En az bir renk ya da beden seç; ürünün seçeneği yoksa alttaki kutuyu işaretle.");
    setStep(3);
  }

  async function leaveBarcodes() {
    setError(null);
    if (payload.length === 0) return setError("En az bir seçenek işaretli kalmalı.");
    const seen = new Set<string>();
    for (const c of payload) {
      for (const b of c.barcodes) {
        if (b.length < 3 || b.length > 64) return setError(`Barkod 3 ile 64 karakter arasında olmalı: ${b}`);
        if (seen.has(b)) return setError(`Aynı barkod iki seçeneğe yazılmış: ${b}`);
        seen.add(b);
        const known = knownBarcodes[b];
        if (known) return setError(`${b} barkodu zaten "${known.product_name}" ürününde kullanılıyor. Etiketi kontrol et.`);
      }
    }
    // Every code is checked against the business here as well, not only on field blur: a
    // scanner types and sends Enter without ever blurring the field, and the database
    // would otherwise refuse the whole product only at the final save.
    setBusy(true);
    try {
      for (const code of seen) {
        const res = await lookupBarcodeAction(code);
        if (!res.ok) return setError(res.error);
        if (res.data) {
          const owner: KnownBarcode = { product_id: res.data.product_id, product_name: res.data.product_name, label: res.data.sku };
          setKnownBarcodes((prev) => ({ ...prev, [code]: owner }));
          return setError(`${code} barkodu zaten "${owner.product_name}" ürününde kullanılıyor. Etiketi kontrol et.`);
        }
      }
    } finally {
      setBusy(false);
    }
    setStep(4);
  }

  // ------------------------------------------------------------ save

  async function save() {
    // one click, one product: the ref guards the window before React re-renders the disabled button
    if (submitting.current) return;
    submitting.current = true;
    setBusy(true);
    setError(null);
    setProgress({ phase: "product", imageIndex: 0, imageTotal: 0, imageErrors: [] });

    const res = await onboardProductAction({ identity, combos: payload });
    if (!res.ok) {
      submitting.current = false;
      setBusy(false);
      setProgress(null);
      setError(res.error);
      return;
    }

    // Photos, in order: main, label, then one per colour (attached to that colour's first new piece).
    const uploads: Array<{ label: string; file: File; role: "product_main" | "label_tag" | "variant"; variantId?: string }> = [];
    if (mainPhoto) uploads.push({ label: "Ürün fotoğrafı", file: mainPhoto.file, role: "product_main" });
    if (labelPhoto) uploads.push({ label: "Etiket fotoğrafı", file: labelPhoto.file, role: "label_tag" });
    for (const [valueId, photo] of Object.entries(colorPhotos)) {
      const combo = combos.find((c) => c.enabled && c.values.some((v) => v.value_id === valueId));
      const created = combo ? res.data.variants.find((v) => v.sku === combo.sku.trim() && v.created) : undefined;
      if (created) uploads.push({ label: `${combo!.values.find((v) => v.value_id === valueId)?.value ?? "Renk"} fotoğrafı`, file: photo.file, role: "variant", variantId: created.variant_id });
    }

    const imageErrors: string[] = [];
    for (let i = 0; i < uploads.length; i++) {
      const u = uploads[i];
      setProgress({ phase: "images", imageIndex: i + 1, imageTotal: uploads.length, imageErrors });
      const fd = new FormData();
      fd.set("product_id", res.data.product_id);
      fd.set("role", u.role);
      if (u.variantId) fd.set("variant_id", u.variantId);
      fd.set("file", u.file);
      const up = await uploadIntakeImageAction(fd);
      if (!up.ok) imageErrors.push(`${u.label}: ${up.error}`);
    }

    setProgress({ phase: "done", imageIndex: uploads.length, imageTotal: uploads.length, imageErrors });
    setResult(res.data);
    setBusy(false);
    router.refresh();
  }

  function resetAll() {
    for (const p of [mainPhoto, labelPhoto, ...Object.values(colorPhotos)]) if (p) URL.revokeObjectURL(p.url);
    submitting.current = false;
    setStep(1);
    setIdentity(EMPTY_IDENTITY);
    setMainPhoto(null);
    setLabelPhoto(null);
    setDuplicates(null);
    setDuplicatesAccepted(false);
    setSelected({});
    setNoOptions(false);
    setDisabled({});
    setBarcodeEdits({});
    setColorPhotos({});
    setKnownBarcodes({});
    setError(null);
    setProgress(null);
    setResult(null);
    window.scrollTo({ top: 0 });
  }

  // ------------------------------------------------------------ render

  if (result && progress?.phase === "done") {
    const created = result.variants.filter((v) => v.created).length;
    const barcodes = result.variants.reduce((n, v) => n + v.barcodes_added, 0);
    return (
      <div className="space-y-6" data-testid="intake-success">
        <div className="flex flex-col items-center gap-4 rounded border border-border bg-surface px-5 py-8 text-center">
          <span className="inline-flex h-12 w-12 items-center justify-center rounded-full bg-success-muted text-success"><CheckCircle2 aria-hidden className="h-6 w-6" /></span>
          <h2 className="font-serif text-3xl font-medium leading-tight text-text-primary">Ürün hazır.</h2>
          <div className="flex items-center gap-3">
            {mainPhoto ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={mainPhoto.url} alt={identity.name} className="h-14 w-14 rounded border border-border object-cover" />
            ) : null}
            <div className="text-left">
              <p className="text-sm font-medium">{identity.name}</p>
              <p className="text-xs text-text-muted" data-numeric>
                {created === 1 && result.variants[0]?.sku ? "Tek seçenek" : `${created} ürün seçeneği`} · {barcodes} barkod
                {progress.imageTotal > 0 ? ` · ${progress.imageTotal - progress.imageErrors.length}/${progress.imageTotal} fotoğraf` : ""}
              </p>
            </div>
          </div>
          <p className="max-w-sm text-sm text-text-secondary">Stok henüz girilmedi. Raftaki adetleri sayımla ekleyebilirsin.</p>
        </div>
        {progress.imageErrors.length > 0 ? (
          <Notice tone="warning">
            Bazı fotoğraflar yüklenemedi; ürün sayfasından yeniden ekleyebilirsin.
            <ul className="mt-1 list-disc pl-5 text-xs">
              {progress.imageErrors.map((e) => (
                <li key={e}>{e}</li>
              ))}
            </ul>
          </Notice>
        ) : null}
        <div className="flex flex-col gap-2 sm:flex-row sm:justify-center">
          <Link href="/app/stok/sayim" className="contents">
            <Button size="lg" className="w-full sm:w-auto">Stok say</Button>
          </Link>
          <Button size="lg" variant="outline" onClick={resetAll} className="w-full sm:w-auto">Yeni ürün ekle</Button>
          <Link href={`/app/urunler/${result.product_id}`} className="contents">
            <Button size="lg" variant="ghost" className="w-full sm:w-auto">Ürünü gör</Button>
          </Link>
        </div>
      </div>
    );
  }

  const back = () => {
    setError(null);
    setStep((s) => (s > 1 ? ((s - 1) as Step) : s));
  };

  const next = step === 1 ? leaveProduct : step === 2 ? leaveOptions : step === 3 ? leaveBarcodes : save;
  const nextLabel =
    step === 1 ? (busy ? "Kontrol ediliyor…" : "Devam")
    : step === 2 ? "Devam"
    : step === 3 ? (busy ? "Barkodlar kontrol ediliyor…" : payload.every((c) => c.barcodes.length === 0) ? "Barkodsuz devam" : "Devam")
    : busy ? "Kaydediliyor…" : "Ürünü kaydet";

  return (
    <div className="space-y-6 pb-28">
      <Stepper step={step} />

      {step === 1 ? (
        <StepProduct
          identity={identity}
          onChange={updateIdentity}
          categories={categories}
          onCategoryCreated={(c) => {
            setCategories((prev) => [...prev, c]);
            setIdentity((p) => ({ ...p, category_id: c.id }));
          }}
          brands={brands}
          mainPhoto={mainPhoto}
          labelPhoto={labelPhoto}
          onMainPhoto={setMainPhoto}
          onLabelPhoto={setLabelPhoto}
          duplicates={duplicates}
          onContinueAsNew={() => {
            setDuplicatesAccepted(true);
            setDuplicates(null);
            setStep(2);
          }}
        />
      ) : null}

      {step === 2 ? (
        <StepOptions
          colorOption={colorOption}
          sizeOption={sizeOption}
          selected={selected}
          onToggle={(optionId, valueId) => {
            setError(null);
            setSelected((prev) => {
              const cur = prev[optionId] ?? [];
              return { ...prev, [optionId]: cur.includes(valueId) ? cur.filter((x) => x !== valueId) : [...cur, valueId] };
            });
          }}
          noOptions={noOptions}
          onNoOptions={(v) => {
            setError(null);
            setNoOptions(v);
          }}
          onOptionChanged={(option) => setOptions((prev) => (prev.some((o) => o.id === option.id) ? prev.map((o) => (o.id === option.id ? option : o)) : [...prev, option]))}
          existing={null}
        />
      ) : null}

      {step === 3 ? (
        <StepBarcodes
          combos={combos}
          colorValues={groups.find((g) => g[0]?.option_kind === "color") ?? []}
          onToggle={(key, on) => {
            setError(null);
            setDisabled((prev) => ({ ...prev, [key]: !on }));
          }}
          onBarcodes={(key, codes) => {
            setError(null);
            setBarcodeEdits((prev) => ({ ...prev, [key]: codes }));
          }}
          knownBarcodes={knownBarcodes}
          onKnownBarcode={(code, owner) => setKnownBarcodes((prev) => ({ ...prev, [code]: owner }))}
          colorPhotos={colorPhotos}
          onColorPhoto={(valueId, photo) =>
            setColorPhotos((prev) => {
              const next = { ...prev };
              if (photo) next[valueId] = photo;
              else delete next[valueId];
              return next;
            })
          }
        />
      ) : null}

      {step === 4 ? (
        <StepReview
          identity={identity}
          category={categories.find((c) => c.id === identity.category_id) ?? null}
          brand={brands.find((b) => b.id === identity.brand_id) ?? null}
          combos={combos.filter((c) => c.enabled)}
          mainPhoto={mainPhoto}
          labelPhoto={labelPhoto}
          colorPhotos={colorPhotos}
          progress={progress}
          onFix={(s) => {
            setError(null);
            setStep(s);
          }}
        />
      ) : null}

      {/* Sticky action bar: reachable with a thumb, above the mobile nav. The error sits
          inside it so it is read without scrolling, on a phone and on a desktop alike. */}
      <div className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-background/95 px-4 py-3 backdrop-blur sm:sticky sm:inset-auto sm:bottom-0 sm:px-0">
        {error ? (
          <div className="mx-auto mb-2 max-w-3xl">
            <Notice tone="danger">{error}</Notice>
          </div>
        ) : null}
        <div className="mx-auto flex max-w-3xl items-center justify-between gap-3">
          <Button variant="ghost" onClick={back} disabled={busy || step === 1}>
            Geri
          </Button>
          <span className="text-xs text-text-muted" data-numeric>
            {step >= 3 && payload.length > 0 ? `${payload.length} seçenek` : ""}
          </span>
          <Button onClick={() => void next()} disabled={busy || (step === 4 && payload.length === 0)} size="lg" variant={step === 4 ? "accent" : "solid"} data-testid="intake-next" aria-busy={busy}>
            {nextLabel}
          </Button>
        </div>
      </div>
    </div>
  );
}
