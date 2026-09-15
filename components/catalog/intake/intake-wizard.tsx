"use client";

import { useCallback, useMemo, useState } from "react";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import type { NamedRef, ProductDetail, ProductOption } from "@/lib/catalog/model";
import {
  comboFingerprint,
  comboLabel,
  suggestComboSku,
  suggestPrefix,
  type DuplicateReport,
  type IntakeCombo,
  type IntakeIdentity,
  type IntakeValue,
  type OnboardCombo,
  type OnboardResult,
  type ProductSummary,
} from "@/lib/catalog/intake";
import {
  checkDuplicatesAction,
  loadProductAction,
  lookupBarcodeAction,
  onboardProductAction,
  onboardVariantsAction,
  uploadIntakeImageAction,
} from "@/app/app/urunler/katalog-ekle/actions";
import { StepRail, Notice, type Photo } from "./primitives";
import { StepBarcode } from "./step-barcode";
import { StepIdentity } from "./step-identity";
import { StepOptions } from "./step-options";
import { StepMatrix } from "./step-matrix";
import { StepReview } from "./step-review";

/**
 * Physical catalogue intake: one garment at a time, phone in hand.
 *
 *   1  barcode          known → the existing variant (hard stop) · unknown → carry it on
 *   2  product          name, model code, category, photos; duplicate warning, person decides
 *   3  colour + size    only values physically confirmed; new values added inline
 *   4  variants         confirmed combinations, SKU, label barcodes, optional colour photo
 *   5  review           one explicit "Ürünü kataloğa ekle"
 *
 * Nothing is written before step 5. The save is one transaction for product +
 * variants + barcodes (rpc_onboard_product); photos upload afterwards, one by one, and
 * a failed photo never undoes the product. There is no quantity anywhere in this flow.
 */

type Mode = "new" | "existing";
type Step = 1 | 2 | 3 | 4 | 5;

type SaveProgress = { phase: "product" | "images" | "done"; imageIndex: number; imageTotal: number; imageErrors: string[] };

const EMPTY_IDENTITY: IntakeIdentity = { name: "", style_code: "", sku_prefix: "", category_id: "", brand_id: "", price: "" };

export function IntakeWizard({
  initialOptions,
  initialCategories,
  brands,
}: {
  initialOptions: ProductOption[];
  initialCategories: NamedRef[];
  brands: NamedRef[];
}) {
  const [step, setStep] = useState<Step>(1);
  const [mode, setMode] = useState<Mode>("new");
  const [existing, setExisting] = useState<ProductDetail | null>(null);
  const [scannedCode, setScannedCode] = useState("");

  const [options, setOptions] = useState<ProductOption[]>(initialOptions);
  const [categories, setCategories] = useState<NamedRef[]>(initialCategories);

  const [identity, setIdentity] = useState<IntakeIdentity>(EMPTY_IDENTITY);
  const [prefixTouched, setPrefixTouched] = useState(false);
  const [mainPhoto, setMainPhoto] = useState<Photo | null>(null);
  const [labelPhoto, setLabelPhoto] = useState<Photo | null>(null);
  const [duplicates, setDuplicates] = useState<DuplicateReport | null>(null);
  const [duplicatesAccepted, setDuplicatesAccepted] = useState(false);

  const [selected, setSelected] = useState<Record<string, string[]>>({});
  const [noOptions, setNoOptions] = useState(false);

  const [disabled, setDisabled] = useState<Record<string, boolean>>({});
  const [skuEdits, setSkuEdits] = useState<Record<string, string>>({});
  const [barcodeEdits, setBarcodeEdits] = useState<Record<string, string[]>>({});
  const [colorPhotos, setColorPhotos] = useState<Record<string, Photo>>({});
  const [knownBarcodes, setKnownBarcodes] = useState<Record<string, string>>({});

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [progress, setProgress] = useState<SaveProgress | null>(null);
  const [result, setResult] = useState<OnboardResult | null>(null);

  const colorOption = options.find((o) => o.kind === "color") ?? null;
  const sizeOption = options.find((o) => o.kind === "size") ?? null;

  // ------------------------------------------------------------ derived

  const skuPrefix = mode === "existing" && existing ? existing.sku_prefix : identity.sku_prefix;

  const existingFingerprints = useMemo(
    () =>
      new Set(
        (existing?.variants ?? [])
          .filter((v) => v.status === "active")
          .map((v) => v.options.map((o) => `${o.option_id}:${o.value_id}`).sort().join("|")),
      ),
    [existing],
  );

  const toValue = useCallback(
    (option: ProductOption, valueId: string): IntakeValue | null => {
      const v = option.values.find((x) => x.id === valueId);
      return v ? { option_id: option.id, option_kind: option.kind, value_id: v.id, value: v.value, code: v.code, color_hex: v.color_hex, sort_order: v.sort_order } : null;
    },
    [],
  );

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
    return rows.map((values, index) => {
      const key = values.map((v) => v.value_id).join("+") || "single";
      const exists = existingFingerprints.has(comboFingerprint(values));
      const stored = barcodeEdits[key];
      // The unknown code from step 1 lands on the first row of a new product, once.
      const seed = index === 0 && scannedCode && mode === "new" ? [scannedCode] : [""];
      return {
        key,
        values,
        sku: skuEdits[key] ?? suggestComboSku(skuPrefix, values),
        barcodes: stored ?? seed,
        enabled: !disabled[key] && !exists,
        exists,
      };
    });
  }, [groups, noOptions, existingFingerprints, barcodeEdits, scannedCode, mode, skuEdits, skuPrefix, disabled]);

  const payload: OnboardCombo[] = combos
    .filter((c) => c.enabled)
    .map((c) => ({ sku: c.sku, option_value_ids: c.values.map((v) => v.value_id), barcodes: c.barcodes.map((b) => b.trim()).filter(Boolean) }));

  // ------------------------------------------------------------ step transitions

  function startNew(code: string) {
    setMode("new");
    setExisting(null);
    setScannedCode(code);
    setStep(2);
  }

  async function startExisting(productId: string) {
    setBusy(true);
    setError(null);
    const res = await loadProductAction(productId);
    setBusy(false);
    if (!res.ok) return setError(res.error);
    setMode("existing");
    setExisting(res.data);
    setScannedCode("");
    setSelected({});
    setNoOptions(false);
    setStep(3);
  }

  function updateIdentity(patch: Partial<IntakeIdentity>) {
    setError(null);
    setIdentity((prev) => {
      const next = { ...prev, ...patch };
      if (!prefixTouched && (patch.name !== undefined || patch.style_code !== undefined)) {
        next.sku_prefix = suggestPrefix(next.style_code, next.name);
      }
      return next;
    });
    if (patch.name !== undefined || patch.style_code !== undefined) {
      setDuplicates(null);
      setDuplicatesAccepted(false);
    }
  }

  async function leaveIdentity() {
    setError(null);
    if (identity.name.trim().length < 2) return setError("Ürün adı en az 2 karakter olmalı.");
    if (!identity.sku_prefix.trim()) return setError("SKU ön eki boş olamaz.");
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
    setStep(3);
  }

  function leaveOptions() {
    setError(null);
    if (groups.length === 0 && !noOptions) return setError("En az bir renk ya da beden seçin; seçeneksiz ürün için 'tek varyant' kutusunu işaretleyin.");
    setStep(4);
  }

  async function leaveMatrix() {
    setError(null);
    if (payload.length === 0) return setError("Eklenecek en az bir varyant olmalı.");
    const seen = new Set<string>();
    for (const c of payload) {
      if (!c.sku.trim()) return setError("Her varyantın bir SKU'su olmalı.");
      for (const b of c.barcodes) {
        if (b.length < 3 || b.length > 64) return setError(`Barkod 3 ile 64 karakter arasında olmalı: ${b}`);
        if (seen.has(b)) return setError(`Aynı barkod iki varyanta yazılmış: ${b}`);
        seen.add(b);
        if (knownBarcodes[b]) return setError(`${b} bu işletmede zaten kayıtlı (${knownBarcodes[b]}). Etiketi kontrol edin.`);
      }
    }
    // Every code is checked against the business here as well, not only on field blur: a
    // scanner types and sends Enter without ever blurring the field, and the database
    // would otherwise refuse the whole garment only at the final save.
    setBusy(true);
    try {
      for (const code of seen) {
        const res = await lookupBarcodeAction(code);
        if (!res.ok) return setError(res.error);
        if (res.data) {
          const owner = `${res.data.product_name} · ${res.data.sku}`;
          setKnownBarcodes((prev) => ({ ...prev, [code]: owner }));
          return setError(`${code} bu işletmede zaten kayıtlı (${owner}). Etiketi kontrol edin.`);
        }
      }
    } finally {
      setBusy(false);
    }
    setStep(5);
  }

  // ------------------------------------------------------------ save

  async function save() {
    setBusy(true);
    setError(null);
    setProgress({ phase: "product", imageIndex: 0, imageTotal: 0, imageErrors: [] });

    const res =
      mode === "existing" && existing
        ? await onboardVariantsAction({ product_id: existing.id, combos: payload })
        : await onboardProductAction({ identity, combos: payload });

    if (!res.ok) {
      setBusy(false);
      setProgress(null);
      setError(res.error);
      return;
    }

    // Photos, in order: main, label, then one per colour (attached to that colour's first new variant).
    const uploads: Array<{ label: string; file: File; role: "product_main" | "label_tag" | "variant"; variantId?: string }> = [];
    if (mainPhoto) uploads.push({ label: "Ana görsel", file: mainPhoto.file, role: "product_main" });
    if (labelPhoto) uploads.push({ label: "Etiket", file: labelPhoto.file, role: "label_tag" });
    for (const [valueId, photo] of Object.entries(colorPhotos)) {
      const combo = combos.find((c) => c.enabled && c.values.some((v) => v.value_id === valueId));
      const created = combo ? res.data.variants.find((v) => v.sku === combo.sku.trim() && v.created) : undefined;
      if (created) uploads.push({ label: `Renk görseli · ${combo!.values.find((v) => v.value_id === valueId)?.value ?? ""}`, file: photo.file, role: "variant", variantId: created.variant_id });
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
  }

  function resetAll() {
    for (const p of [mainPhoto, labelPhoto, ...Object.values(colorPhotos)]) if (p) URL.revokeObjectURL(p.url);
    setStep(1);
    setMode("new");
    setExisting(null);
    setScannedCode("");
    setIdentity(EMPTY_IDENTITY);
    setPrefixTouched(false);
    setMainPhoto(null);
    setLabelPhoto(null);
    setDuplicates(null);
    setDuplicatesAccepted(false);
    setSelected({});
    setNoOptions(false);
    setDisabled({});
    setSkuEdits({});
    setBarcodeEdits({});
    setColorPhotos({});
    setKnownBarcodes({});
    setError(null);
    setProgress(null);
    setResult(null);
  }

  // ------------------------------------------------------------ render

  if (result && progress?.phase === "done") {
    const created = result.variants.filter((v) => v.created);
    const skipped = result.variants.length - created.length;
    const barcodes = result.variants.reduce((n, v) => n + v.barcodes_added, 0);
    return (
      <div className="space-y-4">
        <Notice tone="success">
          {mode === "existing" ? "Varyantlar eklendi." : "Ürün kataloğa eklendi."} {created.length} varyant
          {skipped > 0 ? `, ${skipped} kombinasyon zaten vardı` : ""}; {barcodes} barkod
          {progress.imageTotal > 0 ? `; ${progress.imageTotal - progress.imageErrors.length}/${progress.imageTotal} görsel` : ""}.
        </Notice>
        {progress.imageErrors.length > 0 ? (
          <Notice tone="warning">
            Bazı görseller yüklenemedi; ürün sayfasından yeniden ekleyebilirsiniz.
            <ul className="mt-1 list-disc pl-5 text-xs">
              {progress.imageErrors.map((e) => (
                <li key={e}>{e}</li>
              ))}
            </ul>
          </Notice>
        ) : null}
        <ul className="divide-y divide-border border-y border-border text-sm">
          {result.variants.map((v) => (
            <li key={v.variant_id} className="flex items-center justify-between gap-3 py-2">
              <span data-numeric>{v.sku}</span>
              <span className="text-2xs text-text-muted">{v.created ? `${v.barcodes_added} barkod` : "zaten vardı"}</span>
            </li>
          ))}
        </ul>
        <div className="flex flex-wrap gap-2">
          <Button onClick={resetAll}>Sıradaki ürün</Button>
          <Link href={`/app/urunler/${result.product_id}`}>
            <Button variant="outline">Ürün sayfasını aç</Button>
          </Link>
        </div>
      </div>
    );
  }

  const back = () => {
    setError(null);
    if (step === 3 && mode === "existing") return setStep(1);
    setStep((s) => (s > 1 ? ((s - 1) as Step) : s));
  };

  return (
    <div className="space-y-6 pb-24">
      <StepRail step={step} mode={mode} />

      {mode === "existing" && existing && step >= 3 ? (
        <Notice tone="info">
          Mevcut ürüne ekleniyor: <span className="font-medium text-text-primary">{existing.name}</span>{" "}
          <span data-numeric>{existing.sku_prefix}</span> · {existing.variants.filter((v) => v.status === "active").length} aktif varyant
        </Notice>
      ) : null}

      {step === 1 ? (
        <StepBarcode busy={busy} onNew={startNew} onExisting={startExisting} onError={setError} />
      ) : null}

      {step === 2 ? (
        <StepIdentity
          identity={identity}
          onChange={updateIdentity}
          onPrefixEdit={(v) => {
            setPrefixTouched(true);
            setIdentity((p) => ({ ...p, sku_prefix: v }));
          }}
          categories={categories}
          onCategoryCreated={(c) => {
            setCategories((prev) => [...prev, c].sort((a, b) => a.name.localeCompare(b.name, "tr")));
            setIdentity((p) => ({ ...p, category_id: c.id }));
          }}
          brands={brands}
          mainPhoto={mainPhoto}
          labelPhoto={labelPhoto}
          onMainPhoto={setMainPhoto}
          onLabelPhoto={setLabelPhoto}
          duplicates={duplicates}
          onUseExisting={(p: ProductSummary) => startExisting(p.id)}
          onContinueAsNew={() => {
            setDuplicatesAccepted(true);
            setDuplicates(null);
            setStep(3);
          }}
          scannedCode={scannedCode}
        />
      ) : null}

      {step === 3 ? (
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
          existing={existing}
        />
      ) : null}

      {step === 4 ? (
        <StepMatrix
          combos={combos}
          colorValues={groups.find((g) => g[0]?.option_kind === "color") ?? []}
          onToggle={(key, on) => {
            setError(null);
            setDisabled((prev) => ({ ...prev, [key]: !on }));
          }}
          onSku={(key, sku) => {
            setError(null);
            setSkuEdits((prev) => ({ ...prev, [key]: sku }));
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

      {step === 5 ? (
        <StepReview
          mode={mode}
          existing={existing}
          identity={identity}
          category={categories.find((c) => c.id === identity.category_id) ?? null}
          brand={brands.find((b) => b.id === identity.brand_id) ?? null}
          combos={combos.filter((c) => c.enabled)}
          mainPhoto={mainPhoto}
          labelPhoto={labelPhoto}
          colorPhotos={colorPhotos}
          progress={progress}
        />
      ) : null}

      {/* Sticky action bar: reachable with a thumb, above the mobile nav. The error sits
          inside it so it is read without scrolling, on a phone and on a desktop alike. */}
      <div className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-background/95 px-4 py-3 backdrop-blur sm:sticky sm:inset-auto sm:bottom-0 sm:-mx-0 sm:px-0">
        {error ? (
          <div className="mx-auto mb-2 max-w-3xl">
            <Notice tone="danger">{error}</Notice>
          </div>
        ) : null}
        <div className="mx-auto flex max-w-3xl items-center justify-between gap-3">
          <Button variant="ghost" onClick={back} disabled={busy || step === 1}>
            Geri
          </Button>
          <span className="text-2xs text-text-muted" data-numeric>
            {step === 4 || step === 5 ? `${payload.length} varyant` : ""}
          </span>
          {step === 2 ? (
            <Button onClick={leaveIdentity} disabled={busy}>
              {busy ? "Kontrol ediliyor…" : "Devam"}
            </Button>
          ) : step === 3 ? (
            <Button onClick={leaveOptions} disabled={busy}>
              Devam
            </Button>
          ) : step === 4 ? (
            <Button onClick={leaveMatrix} disabled={busy}>
              {busy ? "Barkodlar kontrol ediliyor…" : "Kontrole geç"}
            </Button>
          ) : step === 5 ? (
            <Button onClick={save} disabled={busy || payload.length === 0} size="lg">
              {busy ? "Kaydediliyor…" : mode === "existing" ? "Varyantları ekle" : "Ürünü kataloğa ekle"}
            </Button>
          ) : (
            <span />
          )}
        </div>
      </div>
    </div>
  );
}
