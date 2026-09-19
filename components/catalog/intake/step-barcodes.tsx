"use client";

import { useRef, useState } from "react";
import Link from "next/link";
import { ChevronDown, ScanLine } from "lucide-react";
import { Input } from "@/components/ui/input";
import { PhotoField, type Photo } from "@/components/ui/photo-field";
import { ColorSwatch } from "@/components/catalog/color-swatch";
import { comboLabel, isEan13, type IntakeCombo, type IntakeValue, type KnownBarcode } from "@/lib/catalog/intake";
import { lookupBarcodeAction } from "@/app/app/urunler/katalog-ekle/actions";
import { cn } from "@/lib/utils";

/**
 * Step 3 — optional, late: "Etikette barkod varsa okutabilirsin." One row per colour ×
 * size the person confirmed, each with a barcode field that a scanner types into and
 * leaves with Enter (focus moves to the next row). Codes are kept exactly as printed. A
 * code that already belongs to another piece is named in plain words. Untick a row that
 * is not on hand. The internal SKU is generated and never shown here.
 */
function Row({
  combo,
  index,
  onToggle,
  onBarcodes,
  knownBarcodes,
  onKnownBarcode,
  focusNext,
}: {
  combo: IntakeCombo;
  index: number;
  onToggle: (on: boolean) => void;
  onBarcodes: (codes: string[]) => void;
  knownBarcodes: Record<string, KnownBarcode>;
  onKnownBarcode: (code: string, owner: KnownBarcode) => void;
  focusNext: (index: number) => void;
}) {
  const codes = combo.barcodes.length > 0 ? combo.barcodes : [""];
  const off = !combo.enabled;
  const [checking, setChecking] = useState(false);

  async function checkCode(code: string) {
    const trimmed = code.trim();
    if (trimmed.length < 3 || knownBarcodes[trimmed] !== undefined) return;
    setChecking(true);
    const res = await lookupBarcodeAction(trimmed);
    setChecking(false);
    if (res.ok && res.data) onKnownBarcode(trimmed, { product_id: res.data.product_id, product_name: res.data.product_name, label: res.data.sku });
  }

  const label = combo.values.length === 0 ? "Tek seçenek" : combo.values.map((v) => v.value).join(" · ");

  return (
    <li className={cn("py-3", off && !combo.exists && "opacity-60")} data-combo={label}>
      <div className="flex items-start gap-3">
        <input
          type="checkbox"
          checked={!off}
          disabled={combo.exists}
          onChange={(e) => onToggle(e.target.checked)}
          aria-label={`${comboLabel(combo.values)} elimde var`}
          className="mt-3 h-5 w-5 shrink-0 accent-[var(--accent)]"
        />
        <div className="min-w-0 flex-1 space-y-1.5">
          <p className="flex min-h-11 flex-wrap items-center gap-x-2 text-sm font-medium sm:min-h-8">
            {combo.values.length === 0
              ? "Tek seçenek"
              : combo.values.map((v, i) => (
                  <span key={v.value_id} className="flex items-center gap-2">
                    {i > 0 ? <span className="text-text-muted">·</span> : null}
                    {v.option_kind === "color" ? <ColorSwatch hex={v.color_hex} label={v.value} /> : <span>{v.value}</span>}
                  </span>
                ))}
            {combo.exists ? <span className="text-2xs font-normal text-text-muted">zaten var</span> : null}
            {off && !combo.exists ? <span className="text-2xs font-normal text-text-muted">eklenmeyecek</span> : null}
          </p>
          {!combo.exists && !off
            ? codes.map((code, i) => {
                const trimmed = code.trim();
                const owner = trimmed ? knownBarcodes[trimmed] : undefined;
                return (
                  <div key={i} className="space-y-1">
                    <div className="relative flex items-center gap-2">
                      <ScanLine aria-hidden className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 stroke-[1.5] text-text-muted" />
                      <Input
                        aria-label={`${comboLabel(combo.values)} barkod ${i + 1}`}
                        data-barcode-input={i === 0 ? index : undefined}
                        value={code}
                        onChange={(e) => {
                          const next = [...codes];
                          next[i] = e.target.value;
                          onBarcodes(next);
                        }}
                        onBlur={() => void checkCode(code)}
                        onKeyDown={(e) => {
                          if (e.key === "Enter") {
                            e.preventDefault();
                            void checkCode(code);
                            focusNext(index);
                          }
                        }}
                        placeholder={i === 0 ? "Barkodu okut ya da yaz" : "İkinci barkod"}
                        inputMode="text"
                        autoComplete="off"
                        autoCapitalize="off"
                        spellCheck={false}
                        enterKeyHint="next"
                        aria-invalid={owner ? true : undefined}
                        className={cn("h-11 pl-9 font-mono text-sm sm:h-10", owner && "border-danger")}
                      />
                      {i === codes.length - 1 && codes.length < 3 && trimmed ? (
                        <button type="button" onClick={() => onBarcodes([...codes, ""])} className="min-h-11 shrink-0 text-xs text-text-muted underline underline-offset-4 hover:text-text-primary sm:min-h-9">
                          + barkod
                        </button>
                      ) : i > 0 ? (
                        <button type="button" onClick={() => onBarcodes(codes.filter((_, j) => j !== i))} className="min-h-11 shrink-0 text-xs text-text-muted underline underline-offset-4 hover:text-text-primary sm:min-h-9">
                          kaldır
                        </button>
                      ) : null}
                    </div>
                    {owner ? (
                      <p className="text-xs text-danger" role="alert">
                        Bu barkod zaten <Link href={`/app/urunler/${owner.product_id}`} className="font-medium underline underline-offset-2">{owner.product_name}</Link> ürününde kullanılıyor ({owner.label}). Etiketi kontrol et.
                      </p>
                    ) : checking ? (
                      <p className="text-2xs text-text-muted">Kontrol ediliyor…</p>
                    ) : trimmed && isEan13(trimmed) ? (
                      <p className="text-2xs text-text-muted">Standart barkod (EAN-13)</p>
                    ) : null}
                  </div>
                );
              })
            : null}
        </div>
      </div>
    </li>
  );
}

export function StepBarcodes({
  combos,
  colorValues,
  onToggle,
  onBarcodes,
  knownBarcodes,
  onKnownBarcode,
  colorPhotos,
  onColorPhoto,
}: {
  combos: IntakeCombo[];
  colorValues: IntakeValue[];
  onToggle: (key: string, on: boolean) => void;
  onBarcodes: (key: string, codes: string[]) => void;
  knownBarcodes: Record<string, KnownBarcode>;
  onKnownBarcode: (code: string, owner: KnownBarcode) => void;
  colorPhotos: Record<string, Photo>;
  onColorPhoto: (valueId: string, photo: Photo | null) => void;
}) {
  const listRef = useRef<HTMLUListElement>(null);
  const [morePhotos, setMorePhotos] = useState(Object.keys(colorPhotos).length > 0);
  const enabled = combos.filter((c) => c.enabled).length;
  const withCode = combos.filter((c) => c.enabled && c.barcodes.some((b) => b.trim())).length;

  function focusNext(index: number) {
    const next = listRef.current?.querySelector<HTMLInputElement>(`input[data-barcode-input="${index + 1}"]`);
    next?.focus();
  }

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-base font-medium">Etikette barkod varsa okutabilirsin.</h2>
        <p className="mt-1 text-sm text-text-muted">
          Barkod olmadan da devam edebilirsin. Elinde olmayan bir seçeneğin işaretini kaldır.
          <span className="ml-1" data-numeric>{withCode}/{enabled} seçenekte barkod var.</span>
        </p>
      </div>

      <ul ref={listRef} className="divide-y divide-border border-y border-border">
        {combos.map((combo, i) => (
          <Row
            key={combo.key}
            combo={combo}
            index={i}
            onToggle={(on) => onToggle(combo.key, on)}
            onBarcodes={(codes) => onBarcodes(combo.key, codes)}
            knownBarcodes={knownBarcodes}
            onKnownBarcode={onKnownBarcode}
            focusNext={focusNext}
          />
        ))}
      </ul>

      {colorValues.length > 0 ? (
        <div className="border-t border-border pt-4">
          <button type="button" onClick={() => setMorePhotos((v) => !v)} aria-expanded={morePhotos} className="flex min-h-11 w-full items-center justify-between text-sm font-medium text-text-secondary hover:text-text-primary sm:min-h-9">
            Renk fotoğrafları <span className="text-xs font-normal text-text-muted">isteğe bağlı</span>
            <ChevronDown aria-hidden className={cn("h-4 w-4 transition-transform", morePhotos && "rotate-180")} />
          </button>
          {morePhotos ? (
            <div className="mt-3 space-y-2">
              <p className="text-xs text-text-muted">Renk ana fotoğraftan anlaşılmıyorsa her renk için bir fotoğraf ekleyebilirsin.</p>
              <div className="flex flex-wrap gap-3">
                {colorValues.map((v) => (
                  <PhotoField key={v.value_id} id={`color-photo-${v.value_id}`} label={v.value} photo={colorPhotos[v.value_id] ?? null} onChange={(p) => onColorPhoto(v.value_id, p)} size="sm" />
                ))}
              </div>
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
