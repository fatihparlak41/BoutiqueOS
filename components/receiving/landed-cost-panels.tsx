"use client";

import { useActionState, useState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { FormMessage } from "@/components/catalog/form-message";
import { IDLE } from "@/lib/catalog/action-state";
import {
  addChargeAction,
  deleteChargeAction,
  reverseReceiptAction,
  reviewReceiptAction,
  setAllocationMethodAction,
} from "@/app/app/mal-kabul/landed-actions";
import {
  ALLOCATION_LABELS,
  CHARGE_KIND_LABELS,
  CHARGE_LIABILITY_LABELS,
  CURRENCIES,
  type AllocationMethod,
  type AllocationPreview,
  type ChargeKind,
  type ChargeLiabilityMode,
  type ReceiptCharge,
  type ReceiptDetail,
  type Supplier,
} from "@/lib/receiving/model";
import { formatDateTime, formatMoney, formatQuantity, formatRate } from "@/lib/receiving/format";

/**
 * Phase 8A panels of the receiving screen: additional charges, allocation + review, and
 * the reversal of a posted document. Every number shown for a draft comes from the
 * database preview (the same function POST uses); nothing is computed client-side.
 */

function Pending({ label, pendingLabel, variant = "outline", size = "sm" }: {
  label: string;
  pendingLabel: string;
  variant?: "solid" | "outline" | "ghost";
  size?: "sm" | "md";
}) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size={size} variant={variant} disabled={pending}>
      {pending ? pendingLabel : label}
    </Button>
  );
}

// ------------------------------------------------------------------ charges

function ChargeRow({ receipt, charge, editable }: { receipt: ReceiptDetail; charge: ReceiptCharge; editable: boolean }) {
  const [state, action] = useActionState(deleteChargeAction, IDLE);
  const liability =
    charge.liability_mode === "separate_supplier"
      ? `Borç: ${charge.payee_supplier_name ?? "—"}`
      : charge.liability_mode === "add_to_invoice"
        ? `Borç: ${receipt.supplier_name} (fatura)`
        : "Borç yazılmaz";

  return (
    <li className="py-2.5" data-testid="charge-row">
      <div className="flex flex-wrap items-start gap-x-4 gap-y-1">
        <div className="min-w-[10rem] flex-1">
          <span className="text-sm font-medium">{CHARGE_KIND_LABELS[charge.kind]}</span>
          {charge.description ? <span className="ml-1.5 text-xs text-ink-70">{charge.description}</span> : null}
          <span className="mt-0.5 block text-2xs text-muted">
            {liability}
            {charge.include_in_landed ? " · maliyete dahil" : " · maliyete dahil değil"}
          </span>
        </div>
        <div className="text-right text-sm" data-numeric>
          {formatMoney(charge.amount, charge.currency)}
          {charge.currency !== "TRY" ? (
            <span className="block text-2xs text-muted">
              kur {formatRate(charge.exchange_rate)} → {formatMoney(charge.amount_base, "TRY")}
            </span>
          ) : null}
        </div>
        {editable ? (
          <form action={action}>
            <input type="hidden" name="receipt_id" value={receipt.id} />
            <input type="hidden" name="charge_id" value={charge.id} />
            <Pending label="Sil" pendingLabel="…" variant="ghost" />
          </form>
        ) : null}
      </div>
      {state.error ? <FormMessage state={state} /> : null}
    </li>
  );
}

function AddChargeForm({ receipt, suppliers }: { receipt: ReceiptDetail; suppliers: Supplier[] }) {
  const [state, action] = useActionState(addChargeAction, IDLE);
  const [currency, setCurrency] = useState(receipt.invoice_currency);
  const [mode, setMode] = useState<ChargeLiabilityMode>("add_to_invoice");

  return (
    <form action={action} className="space-y-3 border border-line bg-panel/40 p-4">
      <input type="hidden" name="receipt_id" value={receipt.id} />
      <h4 className="text-xs font-medium text-ink-70">Masraf ekle</h4>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className="space-y-1.5">
          <Label htmlFor="charge-kind">Tür</Label>
          <Select id="charge-kind" name="kind" defaultValue="freight" className="h-11 sm:h-9">
            {(Object.keys(CHARGE_KIND_LABELS) as ChargeKind[]).map((k) => (
              <option key={k} value={k}>{CHARGE_KIND_LABELS[k]}</option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="charge-description">Açıklama</Label>
          <Input id="charge-description" name="description" maxLength={120} className="h-11 sm:h-9" placeholder="Örn. Londra–Lefkoşa kargo" />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="charge-amount">Tutar</Label>
          <Input id="charge-amount" name="amount" inputMode="decimal" required placeholder="0,00" className="h-11 text-right sm:h-9" />
        </div>
        <div className="grid grid-cols-2 gap-2">
          <div className="space-y-1.5">
            <Label htmlFor="charge-currency">Para birimi</Label>
            <Select id="charge-currency" name="currency" value={currency} onChange={(e) => setCurrency(e.target.value as typeof currency)} className="h-11 sm:h-9">
              {CURRENCIES.map((c) => (
                <option key={c} value={c}>{c}</option>
              ))}
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="charge-rate">Kur</Label>
            <Input id="charge-rate" name="exchange_rate" inputMode="decimal" defaultValue={currency === "TRY" ? "1" : ""} disabled={currency === "TRY"} placeholder="? TRY" className="h-11 text-right sm:h-9" />
          </div>
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="charge-mode">Kime borç yazılsın</Label>
          <Select id="charge-mode" name="liability_mode" value={mode} onChange={(e) => setMode(e.target.value as ChargeLiabilityMode)} className="h-11 sm:h-9">
            {(Object.keys(CHARGE_LIABILITY_LABELS) as ChargeLiabilityMode[]).map((m) => (
              <option key={m} value={m}>{CHARGE_LIABILITY_LABELS[m]}</option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="charge-payee">Masrafı kesen tedarikçi</Label>
          <Select id="charge-payee" name="payee_supplier_id" defaultValue="" disabled={mode !== "separate_supplier"} className="h-11 sm:h-9">
            <option value="">Seçin…</option>
            {suppliers.filter((s) => s.status === "active").map((s) => (
              <option key={s.id} value={s.id}>{s.name}</option>
            ))}
          </Select>
        </div>
      </div>

      <label className="flex items-start gap-2 text-xs text-ink-70">
        <input type="checkbox" name="include_in_landed" defaultChecked className="mt-0.5 h-3.5 w-3.5 rounded-sm border-line-strong text-accent focus-visible:ring-2 focus-visible:ring-accent" />
        <span>Ürün maliyetine dahil et (satırlara dağıtılır). Kapalıysa masraf yalnız borç olarak kaydedilir.</span>
      </label>

      <p className="text-2xs leading-relaxed text-muted">
        Fatura tedarikçisine yazılan masraf fatura para biriminde ({receipt.invoice_currency}) olmalıdır. KDV
        ayrıca modellenmez: tutarları belgenizdeki gibi girin.
      </p>

      <FormMessage state={state} successText="Masraf eklendi." />
      <Pending label="Masrafı ekle" pendingLabel="Ekleniyor…" />
    </form>
  );
}

export function ChargesSection({ receipt, suppliers, editable }: { receipt: ReceiptDetail; suppliers: Supplier[]; editable: boolean }) {
  return (
    <section className="space-y-4" data-testid="charges-section">
      <div>
        <h3 className="text-sm font-medium tracking-tightish">Ek masraflar</h3>
        <p className="mt-1 text-xs text-muted">
          Nakliye, gümrük, sigorta gibi masraflar. Maliyete dahil edilenler seçilen yönteme göre
          satırlara dağıtılır ve iniş maliyetini oluşturur.
        </p>
      </div>
      {receipt.charges.length === 0 ? (
        <p className="border border-dashed border-line-strong px-4 py-6 text-center text-xs text-muted">
          Ek masraf yok. Yalnız fatura tutarı maliyet olur.
        </p>
      ) : (
        <ul className="divide-y divide-line border-y border-line">
          {receipt.charges.map((c) => (
            <ChargeRow key={c.id} receipt={receipt} charge={c} editable={editable} />
          ))}
        </ul>
      )}
      {editable ? <AddChargeForm receipt={receipt} suppliers={suppliers} /> : null}
    </section>
  );
}

// ------------------------------------------------------------------ allocation + review

function AllocationMethodForm({ receipt }: { receipt: ReceiptDetail }) {
  const [state, action] = useActionState(setAllocationMethodAction, IDLE);
  return (
    <form action={action} className="flex flex-wrap items-end gap-2">
      <input type="hidden" name="receipt_id" value={receipt.id} />
      <div className="w-full space-y-1.5 sm:w-72">
        <Label htmlFor="allocation-method">Dağıtım yöntemi</Label>
        <Select id="allocation-method" name="allocation_method" defaultValue={receipt.allocation_method} className="h-11 sm:h-9">
          {(Object.keys(ALLOCATION_LABELS) as AllocationMethod[]).map((m) => (
            <option key={m} value={m}>{ALLOCATION_LABELS[m]}</option>
          ))}
        </Select>
      </div>
      <Pending label="Yöntemi kaydet" pendingLabel="Kaydediliyor…" />
      <div className="basis-full">
        <FormMessage state={state} successText="Dağıtım yöntemi kaydedildi." />
      </div>
    </form>
  );
}

export function liabilitySummary(receipt: ReceiptDetail, invoiceTotalOriginal: number) {
  const onInvoice = receipt.charges.filter((c) => c.liability_mode === "add_to_invoice").reduce((s, c) => s + c.amount, 0);
  const separate = new Map<string, number>();
  for (const c of receipt.charges) {
    if (c.liability_mode !== "separate_supplier") continue;
    const key = c.payee_supplier_name ?? "—";
    separate.set(key, (separate.get(key) ?? 0) + c.amount_base);
  }
  return {
    invoice: { supplier: receipt.supplier_name, amount: invoiceTotalOriginal + onInvoice, currency: receipt.invoice_currency },
    separate: [...separate.entries()].map(([supplier, amount]) => ({ supplier, amount })),
  };
}

export function AllocationReviewSection({ receipt, preview }: { receipt: ReceiptDetail; preview: AllocationPreview }) {
  const [reviewState, reviewAction] = useActionState(reviewReceiptAction, IDLE);
  const byItem = new Map(receipt.lines.map((l) => [l.id, l]));
  const invoiceTotal = receipt.lines.reduce((s, l) => s + l.quantity * l.unit_cost, 0);
  const baseTotal = preview.lines.reduce((s, r) => s + r.total_cost_base, 0);
  const chargeTotal = preview.lines.reduce((s, r) => s + r.allocated_charge_base, 0);
  const landedTotal = preview.lines.reduce((s, r) => s + r.landed_total_cost_base, 0);
  const notLanded = receipt.charges.filter((c) => !c.include_in_landed).reduce((s, c) => s + c.amount_base, 0);
  const liabilities = liabilitySummary(receipt, invoiceTotal);
  const empty = receipt.lines.length === 0;

  return (
    <section className="space-y-4" data-testid="review-section">
      <div>
        <h3 className="text-sm font-medium tracking-tightish">Dağıtım ve iniş maliyeti</h3>
        <p className="mt-1 text-xs text-muted">
          İniş maliyeti = birim alış maliyeti (TRY) + satıra düşen masraf payı. Aşağıdaki
          değerler işleme anında kullanılacak hesabın kendisidir.
        </p>
      </div>

      <AllocationMethodForm receipt={receipt} />

      {preview.error ? (
        <p role="alert" className="border-l-2 border-danger bg-panel px-3 py-2 text-xs text-danger" data-testid="preview-error">
          {preview.error}
        </p>
      ) : empty ? (
        <p className="border border-dashed border-line-strong px-4 py-6 text-center text-xs text-muted">
          Satır eklendiğinde dağıtım burada görünür.
        </p>
      ) : (
        <>
          {/* narrow: one card per line */}
          <ul className="divide-y divide-line border-y border-line sm:hidden" data-testid="preview-cards">
            {preview.lines.map((r) => {
              const l = byItem.get(r.item_id);
              return (
                <li key={r.item_id} className="space-y-1 py-2.5 text-sm">
                  <div>
                    <span className="font-medium">{l?.product_name ?? "—"}</span>
                    <span className="mt-0.5 block text-2xs text-muted">{l?.options} · <span data-numeric>{l?.sku}</span></span>
                  </div>
                  <dl className="grid grid-cols-2 gap-x-3 gap-y-0.5 text-xs">
                    <dt className="text-muted">Adet</dt><dd className="text-right" data-numeric>{formatQuantity(r.quantity)}</dd>
                    <dt className="text-muted">Birim (TRY)</dt><dd className="text-right" data-numeric>{formatMoney(r.unit_cost_base, "TRY")}</dd>
                    <dt className="text-muted">Masraf payı</dt><dd className="text-right" data-numeric>{formatMoney(r.allocated_charge_base, "TRY")}</dd>
                    <dt className="text-ink-70">İniş birim</dt><dd className="text-right font-medium" data-numeric>{formatMoney(r.landed_unit_cost_base, "TRY")}</dd>
                    <dt className="text-muted">İniş toplam</dt><dd className="text-right" data-numeric>{formatMoney(r.landed_total_cost_base, "TRY")}</dd>
                  </dl>
                </li>
              );
            })}
          </ul>
          <div className="relative hidden overflow-x-auto sm:block">
            <table className="w-full min-w-[40rem] border-collapse text-sm" data-testid="preview-table">
              <thead>
                <tr className="border-y border-line text-left text-xs text-muted">
                  <th scope="col" className="py-2 pr-4 font-medium">Ürün</th>
                  <th scope="col" className="py-2 pr-4 text-right font-medium">Adet</th>
                  <th scope="col" className="py-2 pr-4 text-right font-medium">Birim ({receipt.invoice_currency})</th>
                  <th scope="col" className="py-2 pr-4 text-right font-medium">Birim (TRY)</th>
                  <th scope="col" className="py-2 pr-4 text-right font-medium">Masraf payı</th>
                  <th scope="col" className="py-2 pr-4 text-right font-medium">İniş birim</th>
                  <th scope="col" className="py-2 text-right font-medium">İniş toplam</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {preview.lines.map((r) => {
                  const l = byItem.get(r.item_id);
                  return (
                    <tr key={r.item_id}>
                      <td className="py-2 pr-4">
                        <span className="font-medium">{l?.product_name ?? "—"}</span>
                        <span className="mt-0.5 block text-2xs text-muted">{l?.options} · <span data-numeric>{l?.sku}</span></span>
                      </td>
                      <td className="py-2 pr-4 text-right" data-numeric>{formatQuantity(r.quantity)}</td>
                      <td className="py-2 pr-4 text-right text-ink-70" data-numeric>{formatMoney(r.unit_cost, receipt.invoice_currency)}</td>
                      <td className="py-2 pr-4 text-right text-ink-70" data-numeric>{formatMoney(r.unit_cost_base, "TRY")}</td>
                      <td className="py-2 pr-4 text-right text-ink-70" data-numeric>{formatMoney(r.allocated_charge_base, "TRY")}</td>
                      <td className="py-2 pr-4 text-right font-medium" data-numeric>{formatMoney(r.landed_unit_cost_base, "TRY")}</td>
                      <td className="py-2 text-right" data-numeric>{formatMoney(r.landed_total_cost_base, "TRY")}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          <dl className="divide-y divide-line border-y border-line text-sm" data-testid="preview-totals">
            {[
              ["Fatura tutarı", formatMoney(invoiceTotal, receipt.invoice_currency)],
              ["Fatura TRY karşılığı", formatMoney(baseTotal, "TRY")],
              ["Maliyete dahil masraflar", formatMoney(chargeTotal, "TRY")],
              ["İniş maliyeti toplamı", formatMoney(landedTotal, "TRY")],
              ...(notLanded > 0 ? [["Maliyete dahil edilmeyen masraflar", formatMoney(notLanded, "TRY")]] : []),
            ].map(([label, value]) => (
              <div key={label} className="flex justify-between gap-6 py-2">
                <dt className="text-muted">{label}</dt>
                <dd className="text-right" data-numeric>{value}</dd>
              </div>
            ))}
          </dl>

          <div data-testid="liability-summary">
            <h4 className="text-xs font-medium text-ink-70">İşlemede oluşacak tedarikçi borçları</h4>
            <ul className="mt-1 divide-y divide-line border-y border-line text-sm">
              <li className="flex justify-between gap-6 py-2">
                <span>{liabilities.invoice.supplier}</span>
                <span data-numeric>{formatMoney(liabilities.invoice.amount, liabilities.invoice.currency)}</span>
              </li>
              {liabilities.separate.map((s) => (
                <li key={s.supplier} className="flex justify-between gap-6 py-2">
                  <span>{s.supplier}</span>
                  <span data-numeric>{formatMoney(s.amount, "TRY")}</span>
                </li>
              ))}
            </ul>
            <p className="mt-1 text-2xs text-muted">Borç, stok değerlemesinden ayrı tutulur; ödeme kaydı ayrı bir adımdır.</p>
          </div>
        </>
      )}

      <form action={reviewAction} className="flex flex-wrap items-center gap-3 border-t border-line pt-3">
        <input type="hidden" name="receipt_id" value={receipt.id} />
        <Pending label={preview.review_current ? "Yeniden gözden geçir" : "Gözden geçir"} pendingLabel="Kontrol ediliyor…" variant={preview.review_current ? "outline" : "solid"} />
        <span className="text-xs" data-testid="review-status" data-current={preview.review_current ? "1" : "0"}>
          {preview.review_current && preview.reviewed_at ? (
            <span className="text-success">Gözden geçirildi · {formatDateTime(preview.reviewed_at)}</span>
          ) : preview.reviewed_at ? (
            <span className="text-danger">Belge son gözden geçirmeden sonra değişti; yeniden gözden geçirin.</span>
          ) : (
            <span className="text-muted">İşlemeden önce gözden geçirme zorunludur.</span>
          )}
        </span>
        <div className="basis-full">
          <FormMessage state={reviewState} successText="Belge gözden geçirildi; işlenebilir." />
        </div>
      </form>
    </section>
  );
}

// ------------------------------------------------------------------ reversal (posted)

export function ReversalPanel({ receipt }: { receipt: ReceiptDetail }) {
  const [state, action] = useActionState(reverseReceiptAction, IDLE);
  const [confirmed, setConfirmed] = useState(false);
  const [reason, setReason] = useState("");

  return (
    <section className="space-y-3 border border-line-strong p-4" data-testid="reversal-panel">
      <h3 className="text-sm font-medium tracking-tightish">Ters kayıt</h3>
      <p className="text-xs leading-relaxed text-muted">
        İşlenmiş belge düzenlenmez. Ters kayıt ayrı bir belge oluşturur: mallar mevcut ortalama
        maliyetle stoktan düşer, tedarikçi borçları eşit tutarda alacaklandırılır. Mallar kısmen
        çıkmışsa ters kayıt reddedilir; tedarikçi iadesi ya da düzeltme kullanın.
      </p>
      <form action={action} className="space-y-3">
        <input type="hidden" name="receipt_id" value={receipt.id} />
        <div className="space-y-1.5">
          <Label htmlFor="reversal-reason">Neden</Label>
          <Input id="reversal-reason" name="reason" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Örn. yanlış tedarikçi faturası" className="h-11 sm:h-9" />
        </div>
        <label className="flex items-start gap-2 text-xs text-ink-70">
          <input type="checkbox" name="confirm" checked={confirmed} onChange={(e) => setConfirmed(e.target.checked)} className="mt-0.5 h-3.5 w-3.5 rounded-sm border-line-strong text-accent focus-visible:ring-2 focus-visible:ring-accent" />
          <span>Bu belgenin stok ve borç etkisini geri almak istiyorum. Ters kayıt da geri alınamaz.</span>
        </label>
        <ReverseButton disabled={!confirmed || reason.trim().length < 3} />
        <FormMessage state={state} successText="Belge ters kaydedildi." />
      </form>
    </section>
  );
}

function ReverseButton({ disabled }: { disabled: boolean }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" variant="outline" disabled={disabled || pending}>
      {pending ? "Ters kaydediliyor…" : "Ters kaydet"}
    </Button>
  );
}
