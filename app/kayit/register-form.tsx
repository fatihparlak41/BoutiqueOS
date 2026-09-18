"use client";

import { useActionState, useState } from "react";
import Link from "next/link";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { PasswordInput } from "@/components/ui/password-input";
import { AuthStatus, FormAlert } from "@/components/auth/auth-status";
import { PASSWORD_MIN_LENGTH } from "@/lib/auth/password";
import { registerAction } from "@/app/kayit/actions";
import {
  BUSINESS_TYPE_OPTIONS,
  COUNTRY_OPTIONS,
  CURRENCY_OPTIONS,
  formatPlanPrice,
  REGISTER_IDLE,
  type PublicPlan,
} from "@/lib/saas/model";
import { cn } from "@/lib/utils";

/**
 * Four steps, one form, one submit at the end. Steps only decide which fields are
 * visible; every field stays mounted (hidden) so the final POST carries all of them
 * and the browser's own validation runs on the visible ones per step.
 *
 * The plan step is informational in 13A: choosing a plan records an intent; no card,
 * no payment, no trial starts here. The sentence on the step says exactly that.
 */

const STEPS = ["Hesabınız", "İşletmeniz", "Plan", "Başvuru"] as const;
type Step = 1 | 2 | 3 | 4;

function Steps({ step }: { step: Step }) {
  return (
    <ol className="flex items-center gap-1 text-2xs text-text-muted" aria-label="Adımlar">
      {STEPS.map((title, i) => {
        const n = (i + 1) as Step;
        const state = n === step ? "current" : n < step ? "done" : "todo";
        return (
          <li key={title} className="flex items-center gap-1">
            <span
              aria-current={state === "current" ? "step" : undefined}
              className={cn(
                "inline-flex h-6 min-w-6 items-center justify-center rounded-full border px-1.5 font-medium",
                state === "current" && "border-accent bg-accent-muted text-accent",
                state === "done" && "border-border-strong bg-surface-muted text-text-secondary",
                state === "todo" && "border-border text-text-muted",
              )}
            >
              {n}
            </span>
            <span className={cn("hidden sm:inline", state === "current" && "text-text-primary")}>{title}</span>
            {n < STEPS.length ? <span aria-hidden className="mx-0.5 h-px w-3 bg-border sm:w-5" /> : null}
          </li>
        );
      })}
    </ol>
  );
}

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="lg" className="w-full" disabled={pending}>
      {pending ? "Gönderiliyor…" : "Hesabı oluştur ve başvur"}
    </Button>
  );
}

export function RegisterForm({ plans }: { plans: PublicPlan[] }) {
  const [state, formAction] = useActionState(registerAction, REGISTER_IDLE);
  const [step, setStep] = useState<Step>(1);
  const [account, setAccount] = useState({ full_name: "", email: "", password: "" });
  const [business, setBusiness] = useState({ business_name: "", country: "TR", currency: "TRY", phone: "", business_type: "butik" });
  const [planId, setPlanId] = useState<string>(plans[0]?.id ?? "");
  const [stepError, setStepError] = useState<string | null>(null);

  if (state.done) {
    return (
      <AuthStatus
        className="mt-8"
        tone="success"
        live
        title="E-postanızı doğrulayın"
        description={
          <>
            <span className="text-text-primary">{state.email}</span> adresine bir doğrulama bağlantısı gönderildi.
            Bağlantıyı açtığınızda başvurunuz oluşturulur ve inceleme sırasına alınır. E-posta gelmediyse gereksiz
            klasörünü kontrol edin.
          </>
        }
        action={
          <Link href="/login" className="text-sm underline-offset-4 hover:underline">
            Girişe dön
          </Link>
        }
      />
    );
  }

  const next = () => {
    setStepError(null);
    if (step === 1) {
      if (account.full_name.trim().length < 2) return setStepError("Ad Soyad gerekli.");
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(account.email.trim())) return setStepError("Geçerli bir e-posta adresi girin.");
      if (account.password.length < PASSWORD_MIN_LENGTH) return setStepError(`Parola en az ${PASSWORD_MIN_LENGTH} karakter olmalı.`);
      return setStep(2);
    }
    if (step === 2) {
      if (business.business_name.trim().length < 2) return setStepError("İşletme adı gerekli.");
      return setStep(3);
    }
    if (step === 3) return setStep(4);
  };
  const back = () => {
    setStepError(null);
    setStep((s) => (s > 1 ? ((s - 1) as Step) : s));
  };

  const selectedPlan = plans.find((p) => p.id === planId) ?? null;
  const countryLabel = COUNTRY_OPTIONS.find((o) => o.value === business.country)?.label ?? business.country;
  const typeLabel = BUSINESS_TYPE_OPTIONS.find((o) => o.value === business.business_type)?.label ?? "—";

  return (
    <form action={formAction} className="mt-8 space-y-6" noValidate>
      <Steps step={step} />

      {/* step 1 — account */}
      <fieldset className={cn("space-y-5", step !== 1 && "hidden")}>
        <legend className="sr-only">Hesabınız</legend>
        <div className="space-y-2">
          <Label htmlFor="full_name">Ad Soyad</Label>
          <Input id="full_name" name="full_name" autoComplete="name" required value={account.full_name} onChange={(e) => setAccount({ ...account, full_name: e.target.value })} />
        </div>
        <div className="space-y-2">
          <Label htmlFor="email">E-posta</Label>
          <Input id="email" name="email" type="email" inputMode="email" autoComplete="email" autoCapitalize="none" spellCheck={false} required value={account.email} onChange={(e) => setAccount({ ...account, email: e.target.value })} />
        </div>
        <div className="space-y-2">
          <Label htmlFor="password">Parola</Label>
          <PasswordInput id="password" name="password" autoComplete="new-password" required minLength={PASSWORD_MIN_LENGTH} value={account.password} onChange={(e) => setAccount({ ...account, password: e.target.value })} />
          <p className="text-2xs text-text-muted">En az {PASSWORD_MIN_LENGTH} karakter.</p>
        </div>
      </fieldset>

      {/* step 2 — business */}
      <fieldset className={cn("space-y-5", step !== 2 && "hidden")}>
        <legend className="sr-only">İşletmeniz</legend>
        <div className="space-y-2">
          <Label htmlFor="business_name">İşletme adı</Label>
          <Input id="business_name" name="business_name" autoComplete="organization" required value={business.business_name} onChange={(e) => setBusiness({ ...business, business_name: e.target.value })} />
        </div>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor="country">Ülke / bölge</Label>
            <Select id="country" name="country" value={business.country} onChange={(e) => setBusiness({ ...business, country: e.target.value })}>
              {COUNTRY_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>{o.label}</option>
              ))}
            </Select>
          </div>
          <div className="space-y-2">
            <Label htmlFor="currency">Ana para birimi</Label>
            <Select id="currency" name="currency" value={business.currency} onChange={(e) => setBusiness({ ...business, currency: e.target.value })}>
              {CURRENCY_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>{o.label}</option>
              ))}
            </Select>
          </div>
        </div>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor="business_type">İşletme türü</Label>
            <Select id="business_type" name="business_type" value={business.business_type} onChange={(e) => setBusiness({ ...business, business_type: e.target.value })}>
              {BUSINESS_TYPE_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>{o.label}</option>
              ))}
            </Select>
          </div>
          <div className="space-y-2">
            <Label htmlFor="phone">Telefon <span className="text-text-muted">(isteğe bağlı)</span></Label>
            <Input id="phone" name="phone" type="tel" inputMode="tel" autoComplete="tel" value={business.phone} onChange={(e) => setBusiness({ ...business, phone: e.target.value })} />
          </div>
        </div>
      </fieldset>

      {/* step 3 — plan */}
      <fieldset className={cn("space-y-4", step !== 3 && "hidden")}>
        <legend className="sr-only">Plan</legend>
        {plans.length === 0 ? (
          <p className="text-sm text-text-muted">Şu anda sunulan bir plan yok; başvurunuz plan seçilmeden alınır.</p>
        ) : (
          <ul className="space-y-2">
            {plans.map((p) => (
              <li key={p.id}>
                <label className={cn("flex cursor-pointer items-start gap-3 rounded border px-4 py-3 transition-colors", planId === p.id ? "border-accent bg-accent-muted/40" : "border-border hover:border-border-strong")}>
                  <input type="radio" name="plan_id" value={p.id} checked={planId === p.id} onChange={() => setPlanId(p.id)} className="mt-1" />
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
        <p className="text-xs leading-relaxed text-text-muted">
          Ödeme, başvuru onayından sonra tamamlanacaktır. Bu adımda kart bilgisi istenmez ve hiçbir ücret alınmaz.
        </p>
      </fieldset>

      {/* step 4 — review */}
      <div className={cn("space-y-4", step !== 4 && "hidden")}>
        <dl className="divide-y divide-border border-y border-border text-sm">
          <div className="flex justify-between gap-4 py-2"><dt className="text-text-muted">Hesap</dt><dd className="text-right text-text-primary">{account.full_name}<br /><span className="text-text-muted">{account.email}</span></dd></div>
          <div className="flex justify-between gap-4 py-2"><dt className="text-text-muted">İşletme</dt><dd className="text-right text-text-primary">{business.business_name}<br /><span className="text-text-muted">{countryLabel} · {business.currency} · {typeLabel}</span></dd></div>
          <div className="flex justify-between gap-4 py-2"><dt className="text-text-muted">Plan</dt><dd className="text-right text-text-primary">{selectedPlan ? `${selectedPlan.name} — ${formatPlanPrice(selectedPlan)}` : "Seçilmedi"}</dd></div>
        </dl>
        <p className="text-xs leading-relaxed text-text-muted">
          Hesabı oluşturduğunuzda e-posta adresinize bir doğrulama bağlantısı gönderilir. Başvurunuz doğrulamadan sonra
          inceleme sırasına alınır; onaylandığında işletmeniz sizin sahipliğinizde açılır.
        </p>
      </div>

      {stepError ? <FormAlert>{stepError}</FormAlert> : null}
      {state.error ? <FormAlert id="register-error">{state.error}</FormAlert> : null}

      <div className="flex items-center gap-3">
        {step > 1 ? (
          <Button type="button" variant="outline" size="lg" onClick={back}>
            Geri
          </Button>
        ) : null}
        {step < 4 ? (
          <Button type="button" size="lg" className="flex-1" onClick={next}>
            Devam
          </Button>
        ) : (
          <div className="flex-1">
            <SubmitButton />
          </div>
        )}
      </div>
    </form>
  );
}
