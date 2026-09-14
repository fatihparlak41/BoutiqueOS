"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Badge } from "@/components/ui/badge";
import { FormMessage } from "@/components/catalog/form-message";
import { ColorSwatch } from "@/components/catalog/color-swatch";
import { IDLE } from "@/lib/catalog/action-state";
import { OPTION_KIND_LABELS, type ProductOption } from "@/lib/catalog/model";
import { createOptionAction, createOptionValueAction } from "@/app/app/urunler/actions";

/**
 * Options and their values are business data, not a hard-coded list. Colour and size are
 * the two dimensions fashion needs today; the kind is only a hint for the UI (swatches,
 * ordering) — the database treats every option the same way. Values carry an explicit
 * sort order so a size run renders XS…XL or 34…44, never alphabetically.
 */

function InlineSubmit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="sm" variant="outline" disabled={pending}>
      {pending ? "…" : label}
    </Button>
  );
}

function OptionRow({ option, canEdit }: { option: ProductOption; canEdit: boolean }) {
  const [state, formAction] = useActionState(createOptionValueAction, IDLE);
  const nextSort = (option.values.reduce((m, v) => Math.max(m, v.sort_order), 0) || 0) + 10;

  return (
    <div className="py-4">
      <div className="flex flex-wrap items-center gap-2">
        <h3 className="text-sm font-medium">{option.name}</h3>
        <Badge tone={option.kind === "color" ? "accent" : option.kind === "size" ? "olive" : "neutral"}>
          {OPTION_KIND_LABELS[option.kind]}
        </Badge>
        <span className="text-2xs text-text-muted" data-numeric>{option.values.length} değer</span>
      </div>

      {option.values.length > 0 ? (
        <ul className="mt-2 flex flex-wrap gap-1.5">
          {option.values.map((value) => (
            <li key={value.id} className="rounded-sm border border-border-strong bg-surface-muted px-1.5 py-0.5 text-2xs text-text-secondary">
              {option.kind === "color" ? <ColorSwatch hex={value.color_hex} label={value.value} /> : value.value}
              {value.code ? <span className="ml-1 text-text-muted">{value.code}</span> : null}
            </li>
          ))}
        </ul>
      ) : (
        <p className="mt-2 text-2xs text-text-muted">Bu seçeneğin henüz değeri yok.</p>
      )}

      {canEdit ? (
        <form action={formAction} className="mt-3 flex flex-wrap items-end gap-2">
          <input type="hidden" name="product_option_id" value={option.id} />
          <input type="hidden" name="sort_order" value={nextSort} />
          <Input
            name="option_value"
            required
            maxLength={60}
            placeholder={option.kind === "size" ? "Beden (örn. M, 38, S/M)" : option.kind === "color" ? "Renk (örn. Siyah, Leopar)" : `${option.name} değeri`}
            className="h-11 w-44 text-xs sm:h-8"
            aria-label={`${option.name} için yeni değer`}
          />
          <Input
            name="option_code"
            maxLength={16}
            placeholder="Kısa kod"
            className="h-11 w-24 text-xs uppercase sm:h-8"
            aria-label="SKU için kısa kod"
            spellCheck={false}
          />
          {option.kind === "color" ? (
            <Input
              name="color_hex"
              maxLength={7}
              placeholder="#RRGGBB"
              className="h-11 w-24 font-mono text-xs sm:h-8"
              aria-label="Renk kodu (yalnız görünüm için)"
              spellCheck={false}
            />
          ) : null}
          <InlineSubmit label="Ekle" />
        </form>
      ) : null}

      <div className="mt-2">
        <FormMessage state={state} successText="Değer eklendi." />
      </div>
    </div>
  );
}

export function OptionManager({ options, canEdit }: { options: ProductOption[]; canEdit: boolean }) {
  const [state, formAction] = useActionState(createOptionAction, IDLE);

  return (
    <div className="space-y-3">
      {options.length === 0 ? (
        <p className="text-sm text-text-muted">
          Henüz seçenek tanımlı değil. Renk ve beden ekleyin; değerleri her üründe yeniden kullanılır.
        </p>
      ) : (
        <div className="divide-y divide-border border-y border-border">
          {options.map((option) => (
            <OptionRow key={option.id} option={option} canEdit={canEdit} />
          ))}
        </div>
      )}

      {canEdit ? (
        <form action={formAction} className="flex flex-wrap items-end gap-2 pt-1">
          <Input
            name="option_name"
            required
            maxLength={40}
            placeholder="Yeni seçenek (örn. Renk, Beden, Kalıp)"
            className="h-11 w-56 text-xs sm:h-8"
            aria-label="Yeni seçenek adı"
          />
          <Select name="option_kind" defaultValue="other" className="h-11 w-32 text-xs sm:h-8" aria-label="Seçenek türü">
            <option value="color">{OPTION_KIND_LABELS.color}</option>
            <option value="size">{OPTION_KIND_LABELS.size}</option>
            <option value="other">{OPTION_KIND_LABELS.other}</option>
          </Select>
          <InlineSubmit label="Seçenek ekle" />
        </form>
      ) : null}

      <FormMessage state={state} successText="Seçenek eklendi." />
    </div>
  );
}
