"use client";

import { useActionState, useMemo, useState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { FormMessage } from "@/components/catalog/form-message";
import { ColorSwatch } from "@/components/catalog/color-swatch";
import { suggestSku } from "@/lib/catalog/format";
import type { OptionValue, ProductOption, VariantRow } from "@/lib/catalog/model";
import { IDLE } from "@/lib/catalog/action-state";
import { generateVariantsAction, type MatrixCombo } from "@/app/app/urunler/actions";
import { cn } from "@/lib/utils";

/**
 * Matrix builder: pick the values of each option that this product comes in, review the
 * generated combinations, switch off the ones that do not exist, save. Options are the
 * business's own dimensions (colour, size, and anything added later); a product with
 * no options gets exactly one variant.
 *
 * Everything decided here is a proposal. rpc_generate_variants recomputes the
 * fingerprints, refuses a foreign value, skips combinations that already exist and
 * writes the rest in one transaction.
 */

type Selection = Record<string, string[]>; // option id -> chosen value ids

function cartesian(groups: OptionValue[][]): OptionValue[][] {
  return groups.reduce<OptionValue[][]>((acc, group) => acc.flatMap((row) => group.map((v) => [...row, v])), [[]]);
}

function SubmitButton({ count }: { count: number }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" disabled={pending || count === 0}>
      {pending ? "Oluşturuluyor…" : count === 0 ? "Kombinasyon seçin" : `${count} varyant oluştur`}
    </Button>
  );
}

export function MatrixBuilder({
  productId,
  skuPrefix,
  options,
  existing,
}: {
  productId: string;
  skuPrefix: string;
  options: ProductOption[];
  existing: VariantRow[];
}) {
  const [state, formAction] = useActionState(generateVariantsAction, IDLE);
  const [selection, setSelection] = useState<Selection>({});
  const [disabled, setDisabled] = useState<Record<string, boolean>>({});
  const [skuEdits, setSkuEdits] = useState<Record<string, string>>({});

  const usable = useMemo(() => options.filter((o) => o.values.length > 0), [options]);
  const activeFingerprints = useMemo(
    () =>
      new Set(
        existing
          .filter((v) => v.status === "active")
          .map((v) => v.options.map((o) => `${o.option_id}:${o.value_id}`).sort().join("|")),
      ),
    [existing],
  );

  const groups = useMemo(
    () =>
      usable
        .map((o) => (selection[o.id] ?? []).map((id) => o.values.find((v) => v.id === id)).filter((v): v is OptionValue => !!v))
        .filter((g) => g.length > 0),
    [usable, selection],
  );

  const ownerOf = useMemo(() => {
    const m = new Map<string, string>();
    for (const o of usable) for (const v of o.values) m.set(v.id, o.id);
    return m;
  }, [usable]);

  const combos = useMemo(() => {
    // A business with options but no selection has nothing to create yet; only a
    // business without any option values gets the single option-less variant.
    if (groups.length === 0 && usable.length > 0) return [];
    const rows = groups.length === 0 ? [[]] : cartesian(groups);
    return rows.map((values) => {
      const ids = values.map((v) => v.id);
      const fp = values.map((v) => `${ownerOf.get(v.id)}:${v.id}`).sort().join("|");
      const key = ids.join("+") || "single";
      const label = values.map((v) => v.value).join(" / ") || "Tek varyant";
      const sku = skuEdits[key] ?? suggestSku(skuPrefix, values.map((v) => v.code ?? v.value));
      return { key, label, values, ids, sku, exists: activeFingerprints.has(fp) };
    });
  }, [groups, usable.length, ownerOf, skuPrefix, skuEdits, activeFingerprints]);

  const payload: MatrixCombo[] = combos
    .filter((c) => !c.exists && !disabled[c.key])
    .map((c) => ({ sku: c.sku, option_value_ids: c.ids, enabled: true }));

  const showMatrix = groups.length > 0 || usable.length === 0;

  function toggleValue(optionId: string, valueId: string) {
    setSelection((prev) => {
      const current = prev[optionId] ?? [];
      const next = current.includes(valueId) ? current.filter((id) => id !== valueId) : [...current, valueId];
      return { ...prev, [optionId]: next };
    });
  }

  return (
    <form action={formAction} className="space-y-6">
      <input type="hidden" name="product_id" value={productId} />
      <input type="hidden" name="combos" value={JSON.stringify(payload)} />

      {usable.length === 0 ? (
        <p className="text-sm text-text-muted">
          Bu işletmede henüz seçenek değeri yok. Ürün tek varyantla oluşturulur; renk ve beden
          eklemek için önce aşağıdaki seçenekleri tanımlayın.
        </p>
      ) : (
        <div className="space-y-5">
          {usable.map((option) => {
            const chosen = selection[option.id] ?? [];
            return (
              <fieldset key={option.id}>
                <legend className="text-xs font-medium text-text-secondary">
                  {option.name}
                  <span className="ml-2 font-normal text-text-muted">{chosen.length > 0 ? `${chosen.length} seçili` : "seçilmedi"}</span>
                </legend>
                <div className="mt-2 flex flex-wrap gap-1.5">
                  {option.values.map((value) => {
                    const on = chosen.includes(value.id);
                    return (
                      <button
                        key={value.id}
                        type="button"
                        onClick={() => toggleValue(option.id, value.id)}
                        aria-pressed={on}
                        className={cn(
                          "min-h-9 rounded border px-2.5 py-1 text-xs transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                          on
                            ? "border-accent bg-accent-muted text-accent"
                            : "border-border-strong bg-surface text-text-secondary hover:border-text-muted",
                        )}
                      >
                        {option.kind === "color" ? <ColorSwatch hex={value.color_hex} label={value.value} /> : value.value}
                      </button>
                    );
                  })}
                </div>
              </fieldset>
            );
          })}
        </div>
      )}

      {showMatrix ? (
        <div className="space-y-3">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <h3 className="text-sm font-medium tracking-tightish">
              Kombinasyonlar
              <span className="ml-2 text-xs font-normal text-text-muted" data-numeric>
                {combos.length} toplam, {payload.length} oluşturulacak
              </span>
            </h3>
            {groups.length > 0 ? (
              <p className="text-2xs text-text-muted">{groups.map((g) => g.length).join(" × ")} = {combos.length}</p>
            ) : null}
          </div>

          <ul className="divide-y divide-border border-y border-border">
            {combos.map((combo) => {
              const off = combo.exists || !!disabled[combo.key];
              return (
                <li key={combo.key} className={cn("flex flex-wrap items-center gap-3 py-2", off && !combo.exists && "opacity-60")}>
                  <label className="flex min-w-[12rem] flex-1 items-center gap-2.5 text-sm">
                    <input
                      type="checkbox"
                      checked={!off}
                      disabled={combo.exists}
                      onChange={(e) => setDisabled((prev) => ({ ...prev, [combo.key]: !e.target.checked }))}
                      className="h-4 w-4 accent-[var(--accent)]"
                    />
                    <span className="flex flex-wrap items-center gap-x-2">
                      {combo.values.length === 0
                        ? combo.label
                        : combo.values.map((v) =>
                            usable.find((o) => o.id === ownerOf.get(v.id))?.kind === "color" ? (
                              <ColorSwatch key={v.id} hex={v.color_hex} label={v.value} />
                            ) : (
                              <span key={v.id}>{v.value}</span>
                            ),
                          )}
                    </span>
                    {combo.exists ? <span className="text-2xs text-text-muted">zaten var</span> : null}
                  </label>
                  <Input
                    aria-label={`${combo.label} SKU`}
                    value={combo.sku}
                    disabled={off}
                    onChange={(e) => setSkuEdits((prev) => ({ ...prev, [combo.key]: e.target.value }))}
                    className="h-9 w-56 font-mono text-xs sm:h-8"
                    maxLength={64}
                    spellCheck={false}
                  />
                </li>
              );
            })}
          </ul>
          <p className="text-2xs leading-relaxed text-text-muted">
            SKU&apos;lar ön ek + değer kodlarından türetilir ve düzenlenebilir. Barkodlar varyant oluştuktan
            sonra satırdan eklenir. Var olan kombinasyonlar yeniden oluşturulmaz.
          </p>
        </div>
      ) : (
        <p className="text-xs text-text-muted">Her seçenekten en az bir değer seçin; kombinasyonlar burada listelenir.</p>
      )}

      <FormMessage state={state} />
      <SubmitButton count={payload.length} />
    </form>
  );
}
