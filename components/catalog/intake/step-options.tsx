"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ColorSwatch } from "@/components/catalog/color-swatch";
import type { OptionKind, ProductDetail, ProductOption } from "@/lib/catalog/model";
import { addOptionValueAction, ensureOptionAction } from "@/app/app/urunler/katalog-ekle/actions";
import { Chip } from "./primitives";

/**
 * Step 3. Only what the person can see on the garment: tap the colours it comes in,
 * tap the sizes. A colour or size the business has never listed is added inline and
 * becomes reusable. Nothing is pre-selected. A product with no option at all needs an
 * explicit tick — "single variant" is a statement, not a default.
 */
function OptionPicker({
  kind,
  option,
  chosen,
  onToggle,
  onOptionChanged,
  usedByExisting,
}: {
  kind: Extract<OptionKind, "color" | "size">;
  option: ProductOption | null;
  chosen: string[];
  onToggle: (optionId: string, valueId: string) => void;
  onOptionChanged: (option: ProductOption) => void;
  usedByExisting: Set<string>;
}) {
  const [adding, setAdding] = useState(false);
  const [value, setValue] = useState("");
  const [code, setCode] = useState("");
  const [hex, setHex] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const title = kind === "color" ? "Renk" : "Beden";
  const values = option ? [...option.values].sort((a, b) => a.sort_order - b.sort_order || a.value.localeCompare(b.value, "tr")) : [];

  async function add() {
    setError(null);
    if (value.trim().length === 0) return setError("Değer boş olamaz.");
    setBusy(true);
    let target = option;
    if (!target) {
      const ensured = await ensureOptionAction(kind);
      if (!ensured.ok) {
        setBusy(false);
        return setError(ensured.error);
      }
      target = ensured.data;
    }
    const res = await addOptionValueAction({ option_id: target.id, value, code, color_hex: kind === "color" ? hex : "" });
    setBusy(false);
    if (!res.ok) return setError(res.error);
    const next: ProductOption = { ...target, values: [...target.values, res.data] };
    onOptionChanged(next);
    onToggle(next.id, res.data.id);
    setValue("");
    setCode("");
    setHex("");
    setAdding(false);
  }

  return (
    <section className="space-y-3">
      <div className="flex items-baseline justify-between gap-2">
        <h2 className="text-base font-medium">
          {title}
          <span className="ml-2 text-xs font-normal text-text-muted" data-numeric>{chosen.length > 0 ? `${chosen.length} seçili` : "seçilmedi"}</span>
        </h2>
        <button type="button" onClick={() => setAdding((v) => !v)} className="min-h-11 text-xs text-text-secondary underline underline-offset-4 hover:text-text-primary sm:min-h-8">
          {adding ? "vazgeç" : `Listede olmayan ${title.toLocaleLowerCase("tr-TR")}`}
        </button>
      </div>

      {values.length === 0 && !adding ? (
        <p className="text-sm text-text-muted">Bu işletmede henüz {title.toLocaleLowerCase("tr-TR")} tanımlı değil; sağdaki bağlantıyla ekleyin.</p>
      ) : (
        <div className="flex flex-wrap gap-2">
          {values.map((v) => (
            <Chip key={v.id} on={chosen.includes(v.id)} onClick={() => option && onToggle(option.id, v.id)} title={usedByExisting.has(v.id) ? "Bu üründe zaten kullanılıyor" : undefined}>
              {kind === "color" ? <ColorSwatch hex={v.color_hex} label={v.value} /> : v.value}
              {usedByExisting.has(v.id) ? <span className="ml-1 text-2xs opacity-70">•</span> : null}
            </Chip>
          ))}
        </div>
      )}

      {adding ? (
        <div className="space-y-2 rounded border border-border bg-surface-muted/40 p-3">
          <div className="flex flex-wrap items-end gap-2">
            <div className="min-w-[10rem] flex-1 space-y-1">
              <label htmlFor={`add-${kind}`} className="block text-2xs font-medium text-text-secondary">{title}</label>
              <Input id={`add-${kind}`} value={value} onChange={(e) => setValue(e.target.value)} maxLength={60} placeholder={kind === "color" ? "Örn. Bordo, Leopar" : "Örn. M, 38, S/M"} autoFocus />
            </div>
            <div className="w-24 space-y-1">
              <label htmlFor={`add-${kind}-code`} className="block text-2xs font-medium text-text-secondary">Kısa kod</label>
              <Input id={`add-${kind}-code`} value={code} onChange={(e) => setCode(e.target.value)} maxLength={16} placeholder="SKU için" className="uppercase" spellCheck={false} />
            </div>
            {kind === "color" ? (
              <div className="w-28 space-y-1">
                <label htmlFor="add-color-hex" className="block text-2xs font-medium text-text-secondary">Renk (görünüm)</label>
                <Input id="add-color-hex" value={hex} onChange={(e) => setHex(e.target.value)} maxLength={7} placeholder="#RRGGBB" className="font-mono" spellCheck={false} />
              </div>
            ) : null}
            <Button type="button" size="sm" onClick={add} disabled={busy}>
              {busy ? "…" : "Ekle ve seç"}
            </Button>
          </div>
          {error ? <p className="text-2xs text-danger">{error}</p> : null}
        </div>
      ) : null}
    </section>
  );
}

export function StepOptions({
  colorOption,
  sizeOption,
  selected,
  onToggle,
  noOptions,
  onNoOptions,
  onOptionChanged,
  existing,
}: {
  colorOption: ProductOption | null;
  sizeOption: ProductOption | null;
  selected: Record<string, string[]>;
  onToggle: (optionId: string, valueId: string) => void;
  noOptions: boolean;
  onNoOptions: (v: boolean) => void;
  onOptionChanged: (option: ProductOption) => void;
  existing: ProductDetail | null;
}) {
  const usedByExisting = new Set((existing?.variants ?? []).flatMap((v) => v.options.map((o) => o.value_id)));
  const anySelected = Object.values(selected).some((ids) => ids.length > 0);

  return (
    <div className="space-y-8">
      <p className="text-sm text-text-muted">Yalnız elinizdeki üründe gördüğünüz renk ve bedenleri işaretleyin. Faturadan ya da tahminden değer girmeyin.</p>

      <OptionPicker kind="color" option={colorOption} chosen={colorOption ? (selected[colorOption.id] ?? []) : []} onToggle={onToggle} onOptionChanged={onOptionChanged} usedByExisting={usedByExisting} />
      <OptionPicker kind="size" option={sizeOption} chosen={sizeOption ? (selected[sizeOption.id] ?? []) : []} onToggle={onToggle} onOptionChanged={onOptionChanged} usedByExisting={usedByExisting} />

      {existing ? (
        <p className="text-2xs text-text-muted">• işaretli değerler bu üründe zaten kullanılıyor; var olan kombinasyonlar bir sonraki adımda &quot;zaten var&quot; olarak görünür.</p>
      ) : null}

      <label className={`flex min-h-11 items-center gap-3 border-t border-border pt-5 text-sm ${anySelected ? "opacity-50" : ""}`}>
        <input type="checkbox" checked={noOptions} disabled={anySelected} onChange={(e) => onNoOptions(e.target.checked)} className="h-5 w-5 accent-[var(--accent)]" />
        <span>
          Bu ürünün renk ya da beden seçeneği yok — <span className="text-text-muted">tek varyant olarak eklensin</span>
        </span>
      </label>
    </div>
  );
}
