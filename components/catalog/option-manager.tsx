"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { FormMessage } from "@/components/catalog/form-message";
import { IDLE } from "@/lib/catalog/action-state";
import type { ProductOption } from "@/lib/catalog/model";
import { createOptionAction, createOptionValueAction } from "@/app/app/urunler/actions";

/**
 * Options and their values are business data, not a hard-coded list. Sizes, colours and
 * anything else this boutique needs are added here and become available to every product.
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

  return (
    <div className="py-3">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h4 className="text-sm font-medium">{option.name}</h4>
        <span className="text-2xs text-muted">{option.values.length} değer</span>
      </div>

      {option.values.length > 0 ? (
        <ul className="mt-2 flex flex-wrap gap-1.5">
          {option.values.map((value) => (
            <li
              key={value.id}
              className="rounded-sm border border-line-strong bg-panel px-1.5 py-0.5 text-2xs text-ink-70"
            >
              {value.value}
            </li>
          ))}
        </ul>
      ) : (
        <p className="mt-2 text-2xs text-muted">Bu seçeneğin henüz değeri yok.</p>
      )}

      {canEdit ? (
        <form action={formAction} className="mt-3 flex flex-wrap items-center gap-2">
          <input type="hidden" name="product_option_id" value={option.id} />
          <Input
            name="option_value"
            required
            maxLength={60}
            placeholder={`${option.name} değeri ekle`}
            className="h-11 w-48 text-xs sm:h-8"
            aria-label={`${option.name} için yeni değer`}
          />
          <InlineSubmit label="Ekle" />
        </form>
      ) : null}

      <div className="mt-2">
        <FormMessage state={state} successText="Değer eklendi." />
      </div>
    </div>
  );
}

export function OptionManager({
  options,
  canEdit,
}: {
  options: ProductOption[];
  canEdit: boolean;
}) {
  const [state, formAction] = useActionState(createOptionAction, IDLE);

  return (
    <section className="space-y-2">
      <div>
        <h3 className="text-sm font-medium tracking-tightish">Seçenekler</h3>
        <p className="mt-1 text-xs text-muted">
          İşletme genelinde tanımlı seçenekler. Varyant oluştururken buradaki değerler kullanılır.
        </p>
      </div>

      {options.length === 0 ? (
        <p className="border border-dashed border-line-strong px-4 py-6 text-center text-xs text-muted">
          Henüz seçenek tanımlı değil. Varyant oluşturmak için en az bir seçenek gerekir.
        </p>
      ) : (
        <div className="divide-y divide-line border-y border-line">
          {options.map((option) => (
            <OptionRow key={option.id} option={option} canEdit={canEdit} />
          ))}
        </div>
      )}

      {canEdit ? (
        <form action={formAction} className="flex flex-wrap items-center gap-2 pt-2">
          <Input
            name="option_name"
            required
            maxLength={40}
            placeholder="Yeni seçenek (örn. Kalıp)"
            className="h-11 w-56 text-xs sm:h-8"
            aria-label="Yeni seçenek adı"
          />
          <InlineSubmit label="Seçenek ekle" />
        </form>
      ) : null}

      <FormMessage state={state} successText="Seçenek eklendi." />
    </section>
  );
}
