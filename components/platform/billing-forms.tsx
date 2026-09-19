"use client";

import { useActionState, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import {
  billingSweepAction,
  cancelSubscriptionAction,
  issueInvoiceAction,
  recordPaymentAction,
  setBillingSettingAction,
  voidInvoiceAction,
} from "@/app/platform/actions";
import { PAYMENT_METHODS, PAYMENT_METHOD_LABELS, PLATFORM_IDLE, formatMoney } from "@/lib/saas/model";

/**
 * Billing console forms (Phase 13B, manual billing only). Money arrives outside the app;
 * the platform records it here after seeing it on the bank statement or in the till.
 * There is no card field, no checkout and no provider anywhere on this surface.
 * Every irreversible action is armed by a first click and posted by a second.
 */

function Feedback({ error, ok, okText }: { error: string | null; ok: boolean; okText: string }) {
  if (error) return <p className="text-xs text-danger" role="alert">{error}</p>;
  if (ok) return <p className="text-xs text-text-secondary" role="status">{okText}</p>;
  return null;
}

export function IssueInvoiceForm({ subscriptionId, kind, disabled, disabledReason }: { subscriptionId: string; kind: "first" | "renewal"; disabled?: boolean; disabledReason?: string }) {
  const [state, formAction, pending] = useActionState(issueInvoiceAction, PLATFORM_IDLE);
  const [arm, setArm] = useState(false);
  // explicit lowercase: String.toLowerCase() would turn the Turkish dotted I into "i\u0307"
  const label = kind === "first" ? "İlk faturayı kes" : "Yenileme faturası kes";
  const labelLower = kind === "first" ? "ilk faturayı kes" : "yenileme faturası kes";
  return (
    <form action={formAction} className="space-y-2">
      <input type="hidden" name="subscription_id" value={subscriptionId} />
      {disabled ? (
        <p className="text-xs text-text-muted">{disabledReason ?? "Bu abonelik için şu an fatura kesilemez."}</p>
      ) : !arm ? (
        <Button type="button" size="sm" onClick={() => setArm(true)}>
          {label}…
        </Button>
      ) : (
        <div className="space-y-2">
          <p className="text-xs leading-relaxed text-text-muted">
            Fatura, plan kataloğundaki güncel fiyatla ve {kind === "first" ? "bugünden başlayan" : "önceki dönemin bitiminden başlayan"} bir dönem için kesilir; kesildikten sonra tutarı değişmez.
          </p>
          <div className="space-y-1.5">
            <Label htmlFor={`inv-note-${subscriptionId}`}>Not <span className="text-text-muted">(isteğe bağlı)</span></Label>
            <Input id={`inv-note-${subscriptionId}`} name="note" maxLength={300} />
          </div>
          <div className="flex items-center gap-2">
            <Button type="submit" size="sm" disabled={pending}>
              {pending ? "Kesiliyor…" : `Evet, ${labelLower}`}
            </Button>
            <Button type="button" variant="ghost" size="sm" onClick={() => setArm(false)}>
              Vazgeç
            </Button>
          </div>
        </div>
      )}
      <Feedback error={state.error} ok={state.ok} okText="Fatura kesildi." />
    </form>
  );
}

export function RecordPaymentForm({ invoiceId, currency, balance }: { invoiceId: string; currency: string; balance: number }) {
  const [state, formAction, pending] = useActionState(recordPaymentAction, PLATFORM_IDLE);
  const today = new Date().toISOString().slice(0, 10);
  return (
    <form action={formAction} className="space-y-3 rounded border border-border bg-surface p-4">
      <input type="hidden" name="invoice_id" value={invoiceId} />
      <input type="hidden" name="currency" value={currency} />
      <p className="text-sm font-medium text-text-primary">Ödeme kaydet</p>
      <p className="text-xs leading-relaxed text-text-muted">
        Para BoutiqueOS dışında alınır (havale, nakit, başka bir yol); burada yalnız alındığı kaydedilir. Kalan bakiye{" "}
        <span data-numeric>{formatMoney(balance, currency)}</span>. Tam ödeme faturayı kapatır ve aboneliği aynı işlemde etkinleştirir; fazla ödeme kabul edilmez.
      </p>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="pay-amount">Tutar ({currency})</Label>
          <Input id="pay-amount" name="amount" type="number" inputMode="decimal" min={0.01} max={balance} step="0.01" defaultValue={balance.toFixed(2)} required />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="pay-method">Yöntem</Label>
          <Select id="pay-method" name="method" defaultValue="bank_transfer">
            {PAYMENT_METHODS.map((m) => (
              <option key={m} value={m}>{PAYMENT_METHOD_LABELS[m]}</option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="pay-reference">Referans <span className="text-text-muted">(dekont / makbuz no)</span></Label>
          <Input id="pay-reference" name="reference" maxLength={120} minLength={2} required />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="pay-date">Ödeme tarihi</Label>
          <Input id="pay-date" name="paid_at" type="date" defaultValue={today} max={today} required />
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="pay-note">Not <span className="text-text-muted">(isteğe bağlı)</span></Label>
          <Input id="pay-note" name="note" maxLength={300} />
        </div>
      </div>
      <p className="text-2xs text-text-muted">Aynı referans ikinci kez kaydedilirse tek ödeme sayılır; iki yönetici aynı dekontu girse de mükerrer kayıt oluşmaz.</p>
      <div className="flex items-center gap-3">
        <Button type="submit" size="sm" disabled={pending}>
          {pending ? "Kaydediliyor…" : "Ödemeyi kaydet"}
        </Button>
        <Feedback error={state.error} ok={state.ok} okText="Ödeme kaydedildi." />
      </div>
    </form>
  );
}

export function VoidInvoiceForm({ invoiceId, disabled }: { invoiceId: string; disabled?: boolean }) {
  const [state, formAction, pending] = useActionState(voidInvoiceAction, PLATFORM_IDLE);
  const [arm, setArm] = useState(false);
  return (
    <form action={formAction} className="space-y-3 rounded border border-border bg-surface p-4">
      <input type="hidden" name="invoice_id" value={invoiceId} />
      <p className="text-sm font-medium text-text-primary">Faturayı iptal et</p>
      <p className="text-xs leading-relaxed text-text-muted">Yalnız hiç ödeme almamış açık fatura iptal edilir. Kayıt silinmez; kim, ne zaman, neden iptal etti tutulur. Aynı dönem için yeniden fatura kesilebilir.</p>
      {!arm ? (
        <Button type="button" variant="outline" size="sm" onClick={() => setArm(true)} disabled={disabled}>
          İptal et…
        </Button>
      ) : (
        <div className="space-y-2">
          <div className="space-y-1.5">
            <Label htmlFor="void-reason">Neden</Label>
            <Textarea id="void-reason" name="reason" rows={2} maxLength={300} required />
          </div>
          <div className="flex items-center gap-2">
            <Button type="submit" variant="outline" size="sm" disabled={pending}>
              {pending ? "İptal ediliyor…" : "Evet, faturayı iptal et"}
            </Button>
            <Button type="button" variant="ghost" size="sm" onClick={() => setArm(false)}>
              Vazgeç
            </Button>
          </div>
        </div>
      )}
      <Feedback error={state.error} ok={state.ok} okText="Fatura iptal edildi." />
    </form>
  );
}

const CANCEL_MODES: Array<{ mode: "at_period_end" | "immediate" | "keep"; label: string; hint: string }> = [
  { mode: "at_period_end", label: "Dönem sonunda iptal et", hint: "Ödenmiş dönem sonuna kadar kullanılır; yenileme faturası kesilmez. Dönem bitince tarama iptali uygular." },
  { mode: "immediate", label: "Hemen iptal et", hint: "Abonelik şimdi kapanır. Açık fatura varsa önce iptal edilmelidir. Oransal iade yapılmaz." },
  { mode: "keep", label: "Dönem sonu iptalini geri al", hint: "Planlanmış iptal kaldırılır; yenileme yeniden mümkün olur." },
];

export function CancelSubscriptionForm({ subscriptionId, scheduled }: { subscriptionId: string; scheduled: boolean }) {
  const [state, formAction, pending] = useActionState(cancelSubscriptionAction, PLATFORM_IDLE);
  const [target, setTarget] = useState<(typeof CANCEL_MODES)[number] | null>(null);
  const options = CANCEL_MODES.filter((m) => (scheduled ? m.mode !== "at_period_end" : m.mode !== "keep"));
  return (
    <form action={formAction} className="space-y-2">
      <input type="hidden" name="subscription_id" value={subscriptionId} />
      {target === null ? (
        <div className="flex flex-wrap gap-2">
          {options.map((o) => (
            <Button key={o.mode} type="button" variant="outline" size="sm" onClick={() => setTarget(o)}>
              {o.label}…
            </Button>
          ))}
        </div>
      ) : (
        <div className="space-y-2">
          <input type="hidden" name="mode" value={target.mode} />
          <p className="text-xs leading-relaxed text-text-muted">{target.hint}</p>
          <div className="space-y-1.5">
            <Label htmlFor={`cancel-reason-${subscriptionId}`}>Neden</Label>
            <Input id={`cancel-reason-${subscriptionId}`} name="reason" maxLength={300} required />
          </div>
          <div className="flex items-center gap-2">
            <Button type="submit" size="sm" disabled={pending}>
              {pending ? "Uygulanıyor…" : `Evet: ${target.label}`}
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

export function BillingSweepForm() {
  const [state, formAction, pending] = useActionState(billingSweepAction, PLATFORM_IDLE);
  const [arm, setArm] = useState(false);
  return (
    <form action={formAction} className="space-y-3 rounded border border-border bg-surface p-4">
      <p className="text-sm font-medium text-text-primary">Faturalama taraması</p>
      <p className="text-xs leading-relaxed text-text-muted">
        Vadesi geçmiş açık faturası olan aktif abonelikleri &quot;gecikmiş&quot; işaretler ve dönemi bitmiş planlı iptalleri uygular. Hiçbir işletmeyi askıya almaz;
        işletme durumu ayrı bir karardır. Listeler bu taramaya bağlı değildir — vade her okumada hesaplanır.
      </p>
      {!arm ? (
        <Button type="button" variant="outline" size="sm" onClick={() => setArm(true)}>
          Taramayı çalıştır…
        </Button>
      ) : (
        <div className="flex items-center gap-2">
          <Button type="submit" size="sm" disabled={pending}>
            {pending ? "Çalışıyor…" : "Evet, çalıştır"}
          </Button>
          <Button type="button" variant="ghost" size="sm" onClick={() => setArm(false)}>
            Vazgeç
          </Button>
        </div>
      )}
      <Feedback error={state.error} ok={state.ok} okText={state.message ?? "Tarama tamamlandı."} />
    </form>
  );
}

export function BillingSettingForm({ settingKey, label, hint, value }: { settingKey: "invoice_due_days" | "billing_grace_days"; label: string; hint: string; value: number }) {
  const [state, formAction, pending] = useActionState(setBillingSettingAction, PLATFORM_IDLE);
  return (
    <form action={formAction} className="space-y-2 rounded border border-border bg-surface p-4">
      <input type="hidden" name="key" value={settingKey} />
      <Label htmlFor={`setting-${settingKey}`}>{label}</Label>
      <p className="text-xs leading-relaxed text-text-muted">{hint}</p>
      <div className="flex items-center gap-2">
        <Input id={`setting-${settingKey}`} name="value" type="number" inputMode="numeric" min={0} max={365} defaultValue={value} className="w-24" required />
        <span className="text-xs text-text-muted">gün</span>
        <Button type="submit" size="sm" variant="outline" disabled={pending}>
          {pending ? "Kaydediliyor…" : "Kaydet"}
        </Button>
      </div>
      <Feedback error={state.error} ok={state.ok} okText="Kaydedildi." />
    </form>
  );
}
