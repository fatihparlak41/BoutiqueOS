"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { FormAlert } from "@/components/auth/auth-status";
import { submitApplicationAction } from "@/app/basvuru/actions";
import {
  APPLY_IDLE,
  BUSINESS_TYPE_OPTIONS,
  COUNTRY_OPTIONS,
  CURRENCY_OPTIONS,
  formatPlanPrice,
  type ApplicationDraft,
  type PublicPlan,
} from "@/lib/saas/model";
import { cn } from "@/lib/utils";

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="lg" className="w-full" disabled={pending}>
      {pending ? "Gönderiliyor…" : "Başvuruyu gönder"}
    </Button>
  );
}

/**
 * The application itself, for a confirmed account: prefilled from the registration
 * draft when there is one, empty for an existing user applying for another business.
 * One POST, idempotent on the server.
 */
export function ApplicationForm({ draft, plans }: { draft: ApplicationDraft | null; plans: PublicPlan[] }) {
  const [state, formAction] = useActionState(submitApplicationAction, APPLY_IDLE);
  const defaultPlan = draft?.plan_id && plans.some((p) => p.id === draft.plan_id) ? draft.plan_id : (plans[0]?.id ?? "");

  return (
    <form action={formAction} className="mt-8 space-y-5" noValidate>
      <div className="space-y-2">
        <Label htmlFor="business_name">İşletme adı</Label>
        <Input id="business_name" name="business_name" autoComplete="organization" required defaultValue={draft?.business_name ?? ""} />
      </div>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div className="space-y-2">
          <Label htmlFor="country">Ülke / bölge</Label>
          <Select id="country" name="country" defaultValue={draft?.country ?? "TR"}>
            {COUNTRY_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>{o.label}</option>
            ))}
          </Select>
        </div>
        <div className="space-y-2">
          <Label htmlFor="currency">Ana para birimi</Label>
          <Select id="currency" name="currency" defaultValue={draft?.currency ?? "TRY"}>
            {CURRENCY_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>{o.label}</option>
            ))}
          </Select>
        </div>
      </div>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div className="space-y-2">
          <Label htmlFor="business_type">İşletme türü</Label>
          <Select id="business_type" name="business_type" defaultValue={draft?.business_type ?? "butik"}>
            {BUSINESS_TYPE_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>{o.label}</option>
            ))}
          </Select>
        </div>
        <div className="space-y-2">
          <Label htmlFor="phone">Telefon <span className="text-text-muted">(isteğe bağlı)</span></Label>
          <Input id="phone" name="phone" type="tel" inputMode="tel" autoComplete="tel" defaultValue={draft?.phone ?? ""} />
        </div>
      </div>

      <fieldset className="space-y-3">
        <legend className="text-sm font-medium text-text-primary">Plan</legend>
        {plans.length === 0 ? (
          <p className="text-sm text-text-muted">Şu anda sunulan bir plan yok; başvurunuz plan seçilmeden alınır.</p>
        ) : (
          <ul className="space-y-2">
            {plans.map((p) => (
              <li key={p.id}>
                <label className={cn("flex cursor-pointer items-start gap-3 rounded border border-border px-4 py-3 transition-colors hover:border-border-strong has-[:checked]:border-accent has-[:checked]:bg-accent-muted/40")}>
                  <input type="radio" name="plan_id" value={p.id} defaultChecked={p.id === defaultPlan} className="mt-1" />
                  <span className="min-w-0 flex-1">
                    <span className="flex items-baseline justify-between gap-3">
                      <span className="text-sm font-medium text-text-primary">{p.name}</span>
                      <span className="text-sm text-text-secondary" data-numeric>{formatPlanPrice(p)}</span>
                    </span>
                    {p.description ? <span className="mt-1 block text-xs leading-relaxed text-text-muted">{p.description}</span> : null}
                  </span>
                </label>
              </li>
            ))}
          </ul>
        )}
        <p className="text-xs leading-relaxed text-text-muted">Ödeme, başvuru onayından sonra tamamlanacaktır.</p>
      </fieldset>

      {state.error ? <FormAlert id="apply-error">{state.error}</FormAlert> : null}
      <SubmitButton />
    </form>
  );
}
