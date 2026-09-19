"use client";

import { useActionState, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import {
  approveApplicationAction,
  rejectApplicationAction,
  setBusinessStatusAction,
  setSubscriptionStatusAction,
  upsertPlanAction,
} from "@/app/platform/actions";
import { PLATFORM_IDLE, type BusinessStatus, type SubscriptionStatus } from "@/lib/saas/model";
import type { PlatformPlan } from "@/lib/platform/model";

/**
 * Platform console forms. Every irreversible action asks twice: a plain button arms
 * the form, the second click posts. Errors are the sentences lib/db-errors produces;
 * success re-renders the page from the server (revalidatePath) so the state shown is
 * always what the database holds.
 */

function Feedback({ error, ok, okText }: { error: string | null; ok: boolean; okText: string }) {
  if (error) return <p className="text-xs text-danger" role="alert">{error}</p>;
  if (ok) return <p className="text-xs text-text-secondary" role="status">{okText}</p>;
  return null;
}

export function ApproveApplicationForm({ applicationId, disabled }: { applicationId: string; disabled?: boolean }) {
  const [state, formAction, pending] = useActionState(approveApplicationAction, PLATFORM_IDLE);
  const [arm, setArm] = useState(false);
  return (
    <form action={formAction} className="space-y-3 rounded border border-border bg-surface p-4">
      <input type="hidden" name="application_id" value={applicationId} />
      <p className="text-sm font-medium text-text-primary">Onayla ve işletmeyi aç</p>
      <p className="text-xs leading-relaxed text-text-muted">
        Tek işlemde: işletme (aktif) + ilk sahip üyeliği + &quot;Merkez&quot; şubesi + varsayılan ayarlar + bekleyen abonelik + denetim kaydı.
        Ödeme bu adımda alınmaz; abonelik platform tarafından ayrıca etkinleştirilir.
      </p>
      <div className="space-y-1.5">
        <Label htmlFor="approve-note">Not <span className="text-text-muted">(isteğe bağlı)</span></Label>
        <Input id="approve-note" name="note" maxLength={300} />
      </div>
      {!arm ? (
        <Button type="button" size="sm" onClick={() => setArm(true)} disabled={disabled}>
          Onayla…
        </Button>
      ) : (
        <div className="flex items-center gap-2">
          <Button type="submit" size="sm" disabled={pending || disabled}>
            {pending ? "Açılıyor…" : "Evet, işletmeyi aç"}
          </Button>
          <Button type="button" variant="ghost" size="sm" onClick={() => setArm(false)}>
            Vazgeç
          </Button>
        </div>
      )}
      <Feedback error={state.error} ok={state.ok} okText="Onaylandı." />
    </form>
  );
}

export function RejectApplicationForm({ applicationId, disabled }: { applicationId: string; disabled?: boolean }) {
  const [state, formAction, pending] = useActionState(rejectApplicationAction, PLATFORM_IDLE);
  const [arm, setArm] = useState(false);
  return (
    <form action={formAction} className="space-y-3 rounded border border-border bg-surface p-4">
      <input type="hidden" name="application_id" value={applicationId} />
      <p className="text-sm font-medium text-text-primary">Reddet</p>
      <p className="text-xs leading-relaxed text-text-muted">Neden başvuru sahibine gösterilir. Başvuru geçmişte kalır; kişi yeniden başvurabilir.</p>
      <div className="space-y-1.5">
        <Label htmlFor="reject-note">Neden</Label>
        <Textarea id="reject-note" name="note" rows={2} maxLength={500} required />
      </div>
      {!arm ? (
        <Button type="button" variant="outline" size="sm" onClick={() => setArm(true)} disabled={disabled}>
          Reddet…
        </Button>
      ) : (
        <div className="flex items-center gap-2">
          <Button type="submit" variant="outline" size="sm" disabled={pending || disabled}>
            {pending ? "Reddediliyor…" : "Evet, reddet"}
          </Button>
          <Button type="button" variant="ghost" size="sm" onClick={() => setArm(false)}>
            Vazgeç
          </Button>
        </div>
      )}
      <Feedback error={state.error} ok={state.ok} okText="Reddedildi." />
    </form>
  );
}

const BUSINESS_TRANSITIONS: Record<BusinessStatus, Array<{ to: BusinessStatus; label: string }>> = {
  active: [
    { to: "suspended", label: "Askıya al" },
    { to: "cancelled", label: "Kapat" },
  ],
  suspended: [
    { to: "active", label: "Yeniden aç" },
    { to: "cancelled", label: "Kapat" },
  ],
  cancelled: [{ to: "active", label: "Yeniden aç" }],
};

export function BusinessStatusForm({ businessId, current }: { businessId: string; current: BusinessStatus }) {
  const [state, formAction, pending] = useActionState(setBusinessStatusAction, PLATFORM_IDLE);
  const [target, setTarget] = useState<BusinessStatus | null>(null);
  const options = BUSINESS_TRANSITIONS[current];
  return (
    <form action={formAction} className="space-y-3 rounded border border-border bg-surface p-4">
      <input type="hidden" name="business_id" value={businessId} />
      <p className="text-sm font-medium text-text-primary">İşletme durumu</p>
      <p className="text-xs leading-relaxed text-text-muted">
        Askıdaki ya da kapalı işletmeye hiçbir üye giremez ve hiçbir RPC yazamaz; veriler korunur. Her değişiklik nedeniyle birlikte denetim kaydına yazılır.
      </p>
      {target === null ? (
        <div className="flex flex-wrap gap-2">
          {options.map((o) => (
            <Button key={o.to} type="button" variant="outline" size="sm" onClick={() => setTarget(o.to)}>
              {o.label}…
            </Button>
          ))}
        </div>
      ) : (
        <div className="space-y-2">
          <input type="hidden" name="status" value={target} />
          <div className="space-y-1.5">
            <Label htmlFor="status-reason">Neden</Label>
            <Input id="status-reason" name="reason" maxLength={300} required />
          </div>
          <div className="flex items-center gap-2">
            <Button type="submit" size="sm" disabled={pending}>
              {pending ? "Uygulanıyor…" : `Evet: ${options.find((o) => o.to === target)?.label ?? target}`}
            </Button>
            <Button type="button" variant="ghost" size="sm" onClick={() => setTarget(null)}>
              Vazgeç
            </Button>
          </div>
        </div>
      )}
      <Feedback error={state.error} ok={state.ok} okText="Durum güncellendi." />
    </form>
  );
}

/**
 * Manual moves only. "active" is deliberately absent: since 13B a subscription becomes
 * active when its invoice is paid (RecordPaymentForm), never by hand. Cancellation has
 * its own form (at period end / immediate); this one keeps the bookkeeping moves.
 */
const SUB_TRANSITIONS: Record<SubscriptionStatus, Array<{ to: SubscriptionStatus; label: string }>> = {
  pending: [],
  active: [
    { to: "past_due", label: "Gecikmiş işaretle" },
    { to: "expired", label: "Süresi doldu" },
  ],
  past_due: [{ to: "expired", label: "Süresi doldu" }],
  cancelled: [],
  expired: [],
};

export function SubscriptionStatusForm({ subscriptionId, current }: { subscriptionId: string; current: SubscriptionStatus }) {
  const [state, formAction, pending] = useActionState(setSubscriptionStatusAction, PLATFORM_IDLE);
  const [target, setTarget] = useState<SubscriptionStatus | null>(null);
  const options = SUB_TRANSITIONS[current];
  if (options.length === 0) return null;
  return (
    <form action={formAction} className="space-y-2">
      <input type="hidden" name="subscription_id" value={subscriptionId} />
      {target === null ? (
        <div className="flex flex-wrap gap-2">
          {options.map((o) => (
            <Button key={o.to} type="button" variant="outline" size="sm" onClick={() => setTarget(o.to)}>
              {o.label}…
            </Button>
          ))}
        </div>
      ) : (
        <div className="space-y-2">
          <input type="hidden" name="status" value={target} />
          <div className="space-y-1.5">
            <Label htmlFor={`sub-note-${subscriptionId}`}>Not <span className="text-text-muted">(ör. havale tarihi)</span></Label>
            <Input id={`sub-note-${subscriptionId}`} name="note" maxLength={300} />
          </div>
          <div className="flex items-center gap-2">
            <Button type="submit" size="sm" disabled={pending}>
              {pending ? "Uygulanıyor…" : `Evet: ${options.find((o) => o.to === target)?.label ?? target}`}
            </Button>
            <Button type="button" variant="ghost" size="sm" onClick={() => setTarget(null)}>
              Vazgeç
            </Button>
          </div>
        </div>
      )}
      <Feedback error={state.error} ok={state.ok} okText="Abonelik güncellendi." />
    </form>
  );
}

export function PlanForm({ plan }: { plan: PlatformPlan | null }) {
  const [state, formAction, pending] = useActionState(upsertPlanAction, PLATFORM_IDLE);
  return (
    <form action={formAction} className="grid grid-cols-1 gap-4 rounded border border-border bg-surface p-4 sm:grid-cols-2">
      <div className="space-y-1.5">
        <Label htmlFor="plan-code">Kod</Label>
        <Input id="plan-code" name="code" defaultValue={plan?.code ?? ""} readOnly={Boolean(plan)} pattern="[a-z0-9_]{2,40}" required />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="plan-name">Ad</Label>
        <Input id="plan-name" name="name" defaultValue={plan?.name ?? ""} maxLength={80} required />
      </div>
      <div className="space-y-1.5 sm:col-span-2">
        <Label htmlFor="plan-desc">Açıklama</Label>
        <Input id="plan-desc" name="description" defaultValue={plan?.description ?? ""} maxLength={300} />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="plan-interval">Dönem</Label>
        <Select id="plan-interval" name="billing_interval" defaultValue={plan?.billing_interval ?? "annual"}>
          <option value="annual">Yıllık</option>
          <option value="monthly">Aylık</option>
        </Select>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1.5">
          <Label htmlFor="plan-price">Fiyat</Label>
          <Input id="plan-price" name="price_amount" type="number" inputMode="decimal" min={0} step="0.01" defaultValue={plan?.price_amount ?? ""} required />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="plan-currency">Para birimi</Label>
          <Select id="plan-currency" name="currency" defaultValue={plan?.currency ?? "USD"}>
            <option value="USD">USD</option>
            <option value="EUR">EUR</option>
            <option value="GBP">GBP</option>
            <option value="TRY">TRY</option>
          </Select>
        </div>
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="plan-sort">Sıra</Label>
        <Input id="plan-sort" name="sort_order" type="number" inputMode="numeric" defaultValue={plan?.sort_order ?? 100} />
      </div>
      <label className="flex items-center gap-2 self-end pb-2 text-sm text-text-primary">
        <input type="checkbox" name="is_active" defaultChecked={plan ? plan.is_active : true} /> Kayıt sayfasında sunulsun
      </label>
      <div className="flex items-center gap-3 sm:col-span-2">
        <Button type="submit" size="sm" disabled={pending}>
          {pending ? "Kaydediliyor…" : plan ? "Planı güncelle" : "Plan ekle"}
        </Button>
        <Feedback error={state.error} ok={state.ok} okText="Kaydedildi." />
      </div>
    </form>
  );
}
