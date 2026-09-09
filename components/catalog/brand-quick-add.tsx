"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { FormMessage } from "@/components/catalog/form-message";
import { IDLE } from "@/lib/catalog/action-state";
import { createBrandAction } from "@/app/app/urunler/actions";

/**
 * Sits outside the product form (nested forms are invalid HTML) because a boutique
 * usually discovers it needs a brand while entering the first product of that brand.
 * After saving, the brand appears in the select on the next render.
 */
function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="sm" variant="outline" disabled={pending}>
      {pending ? "Ekleniyor…" : "Marka ekle"}
    </Button>
  );
}

export function BrandQuickAdd() {
  const [state, formAction] = useActionState(createBrandAction, IDLE);

  return (
    <div className="border-t border-line pt-5">
      <h3 className="text-xs font-medium text-ink-70">Marka listesinde yok mu?</h3>
      <p className="mt-1 text-2xs text-muted">
        Yeni markayı buradan ekleyin, yukarıdaki listede görünsün. Kaydedilmemiş form
        alanlarınız korunmaz, önce markayı ekleyin.
      </p>

      <form action={formAction} className="mt-3 flex flex-wrap items-center gap-2">
        <Input
          name="brand_name"
          required
          minLength={2}
          maxLength={80}
          placeholder="Marka adı"
          className="h-8 w-56 text-xs"
          aria-label="Yeni marka adı"
        />
        <SubmitButton />
      </form>

      <div className="mt-2">
        <FormMessage state={state} successText="Marka eklendi." />
      </div>
    </div>
  );
}
