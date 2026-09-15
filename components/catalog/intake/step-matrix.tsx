"use client";

import { Input } from "@/components/ui/input";
import { ColorSwatch } from "@/components/catalog/color-swatch";
import { comboLabel, isEan13, type IntakeCombo, type IntakeValue } from "@/lib/catalog/intake";
import { lookupBarcodeAction } from "@/app/app/urunler/katalog-ekle/actions";
import { PhotoField, type Photo } from "./primitives";
import { cn } from "@/lib/utils";

/**
 * Step 4. Every colour × size the person confirmed, one row each: keep or drop it, the
 * SKU (proposed, editable), the barcode(s) read off that piece's label. Barcodes are
 * kept exactly as typed. Leaving a barcode field checks it against the business and
 * flags a code that already belongs to another variant; step 5 refuses to continue with
 * one. Optional: a photo per colour, when the colour is hard to tell from the main shot.
 */
function ComboRow({
  combo,
  onToggle,
  onSku,
  onBarcodes,
  knownBarcodes,
  onKnownBarcode,
}: {
  combo: IntakeCombo;
  onToggle: (on: boolean) => void;
  onSku: (sku: string) => void;
  onBarcodes: (codes: string[]) => void;
  knownBarcodes: Record<string, string>;
  onKnownBarcode: (code: string, owner: string) => void;
}) {
  const codes = combo.barcodes.length > 0 ? combo.barcodes : [""];
  const off = !combo.enabled;

  async function checkCode(code: string) {
    const trimmed = code.trim();
    if (trimmed.length < 3 || knownBarcodes[trimmed] !== undefined) return;
    const res = await lookupBarcodeAction(trimmed);
    if (res.ok && res.data) onKnownBarcode(trimmed, `${res.data.product_name} · ${res.data.sku}`);
  }

  return (
    <li className={cn("space-y-2 py-3", off && !combo.exists && "opacity-60")}>
      <div className="flex items-center gap-3">
        <input
          type="checkbox"
          checked={!off}
          disabled={combo.exists}
          onChange={(e) => onToggle(e.target.checked)}
          aria-label={`${comboLabel(combo.values)} dahil`}
          className="h-5 w-5 shrink-0 accent-[var(--accent)]"
        />
        <span className="flex min-w-0 flex-1 flex-wrap items-center gap-x-2 text-sm font-medium">
          {combo.values.length === 0
            ? "Tek varyant"
            : combo.values.map((v) => (v.option_kind === "color" ? <ColorSwatch key={v.value_id} hex={v.color_hex} label={v.value} /> : <span key={v.value_id}>{v.value}</span>))}
          {combo.exists ? <span className="text-2xs font-normal text-text-muted">zaten var</span> : null}
        </span>
      </div>

      {!combo.exists ? (
        <div className="grid gap-2 pl-8 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
          <Input aria-label={`${comboLabel(combo.values)} SKU`} value={combo.sku} onChange={(e) => onSku(e.target.value)} disabled={off} maxLength={64} spellCheck={false} className="h-10 font-mono text-xs sm:h-9" />
          <div className="space-y-1.5">
            {codes.map((code, i) => {
              const trimmed = code.trim();
              const owner = trimmed ? knownBarcodes[trimmed] : undefined;
              return (
                <div key={i} className="space-y-1">
                  <div className="flex items-center gap-2">
                    <Input
                      aria-label={`${comboLabel(combo.values)} barkod ${i + 1}`}
                      value={code}
                      onChange={(e) => {
                        const next = [...codes];
                        next[i] = e.target.value;
                        onBarcodes(next);
                      }}
                      onBlur={() => void checkCode(code)}
                      disabled={off}
                      placeholder={i === 0 ? "Etiketteki barkod (yoksa boş)" : "İkinci barkod"}
                      inputMode="text"
                      autoComplete="off"
                      autoCapitalize="off"
                      spellCheck={false}
                      enterKeyHint="next"
                      aria-invalid={owner ? true : undefined}
                      className={cn("h-10 font-mono text-xs sm:h-9", owner && "border-danger")}
                    />
                    {i === codes.length - 1 && codes.length < 3 ? (
                      <button type="button" disabled={off || !trimmed} onClick={() => onBarcodes([...codes, ""])} className="min-h-10 shrink-0 text-2xs text-text-muted underline underline-offset-4 hover:text-text-primary disabled:opacity-40 sm:min-h-9">
                        + barkod
                      </button>
                    ) : (
                      <button type="button" disabled={off} onClick={() => onBarcodes(codes.filter((_, j) => j !== i))} className="min-h-10 shrink-0 text-2xs text-text-muted underline underline-offset-4 hover:text-text-primary sm:min-h-9">
                        kaldır
                      </button>
                    )}
                  </div>
                  {owner ? (
                    <p className="text-2xs text-danger">Zaten kayıtlı: {owner}</p>
                  ) : trimmed && isEan13(trimmed) ? (
                    <p className="text-2xs text-text-muted">EAN-13</p>
                  ) : null}
                </div>
              );
            })}
          </div>
        </div>
      ) : null}
    </li>
  );
}

export function StepMatrix({
  combos,
  colorValues,
  onToggle,
  onSku,
  onBarcodes,
  knownBarcodes,
  onKnownBarcode,
  colorPhotos,
  onColorPhoto,
}: {
  combos: IntakeCombo[];
  colorValues: IntakeValue[];
  onToggle: (key: string, on: boolean) => void;
  onSku: (key: string, sku: string) => void;
  onBarcodes: (key: string, codes: string[]) => void;
  knownBarcodes: Record<string, string>;
  onKnownBarcode: (code: string, owner: string) => void;
  colorPhotos: Record<string, Photo>;
  onColorPhoto: (valueId: string, photo: Photo | null) => void;
}) {
  const enabled = combos.filter((c) => c.enabled).length;
  const existing = combos.filter((c) => c.exists).length;

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-base font-medium">
          Varyantlar
          <span className="ml-2 text-xs font-normal text-text-muted" data-numeric>
            {enabled} eklenecek{existing > 0 ? `, ${existing} zaten var` : ""}
          </span>
        </h2>
        <p className="mt-1 text-xs text-text-muted">Elinizde olmayan kombinasyonun işaretini kaldırın. Barkodu etiketten olduğu gibi yazın; başında sıfır varsa kalır.</p>
      </div>

      <ul className="divide-y divide-border border-y border-border">
        {combos.map((combo) => (
          <ComboRow
            key={combo.key}
            combo={combo}
            onToggle={(on) => onToggle(combo.key, on)}
            onSku={(sku) => onSku(combo.key, sku)}
            onBarcodes={(codes) => onBarcodes(combo.key, codes)}
            knownBarcodes={knownBarcodes}
            onKnownBarcode={onKnownBarcode}
          />
        ))}
      </ul>

      {colorValues.length > 0 ? (
        <section className="space-y-3 border-t border-border pt-5">
          <div>
            <h3 className="text-sm font-medium">Renk fotoğrafı</h3>
            <p className="text-xs text-text-muted">İsteğe bağlı; yalnız renk ana fotoğraftan anlaşılmıyorsa. O rengin ilk varyantına bağlanır.</p>
          </div>
          <div className="grid gap-3 sm:grid-cols-2">
            {colorValues.map((v) => (
              <PhotoField key={v.value_id} id={`color-photo-${v.value_id}`} label={v.value} photo={colorPhotos[v.value_id] ?? null} onChange={(p) => onColorPhoto(v.value_id, p)} compact />
            ))}
          </div>
        </section>
      ) : null}
    </div>
  );
}
