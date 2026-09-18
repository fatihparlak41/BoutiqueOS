"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { FormMessage } from "@/components/catalog/form-message";
import { IDLE } from "@/lib/catalog/action-state";
import {
  approvePoAction, cancelPoAction, closePoAction, createReceiptFromPoAction, orderPoAction, removePoLineAction, updatePoHeaderAction, upsertPoLinesAction,
} from "@/app/app/satin-alma/actions";
import { searchVariantsAction } from "@/app/app/mal-kabul/actions";
import { VARIANT_SEARCH_IDLE, type PickableVariant } from "@/lib/receiving/model";
import { formatMoney, moneyInputValue } from "@/lib/receiving/format";
import type { PoDetail, ProcurementCaps } from "@/lib/po/model";

/**
 * Purchase order workbench. Draft: header, lines (search → matrix rows → quantity, and
 * expected cost for manager+), approve. Approved / ordered / partly received: terms are
 * frozen; expected date and note stay editable; "Mal kabul oluştur" yields a DRAFT receipt
 * that goes through the Phase 8A screen — nothing here moves stock or money.
 */

function Pending({ label, pendingLabel, variant = "outline", size = "sm", testid }: { label: string; pendingLabel: string; variant?: "solid" | "outline" | "ghost"; size?: "sm" | "md"; testid?: string }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" variant={variant} size={size} disabled={pending} data-testid={testid}>
      {pending ? pendingLabel : label}
    </Button>
  );
}

export function PoHeaderForm({ po }: { po: PoDetail }) {
  const [state, formAction] = useActionState(updatePoHeaderAction, IDLE);
  return (
    <form action={formAction} className="grid gap-3 sm:grid-cols-3">
      <input type="hidden" name="po_id" value={po.id} />
      <div className="space-y-1.5">
        <Label htmlFor="expected_date">Beklenen teslim</Label>
        <Input id="expected_date" name="expected_date" type="date" defaultValue={po.expected_date ?? ""} />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="supplier_reference">Tedarikçi referansı</Label>
        <Input id="supplier_reference" name="supplier_reference" defaultValue={po.supplier_reference ?? ""} maxLength={80} />
      </div>
      <div className="space-y-1.5 sm:col-span-3">
        <Label htmlFor="note">Not</Label>
        <Textarea id="note" name="note" defaultValue={po.note ?? ""} rows={2} maxLength={500} />
      </div>
      <div className="flex items-center gap-3 sm:col-span-3">
        <Pending label="Başlığı kaydet" pendingLabel="Kaydediliyor…" />
        <FormMessage state={state} successText="Kaydedildi." />
      </div>
    </form>
  );
}

export function PoLinePicker({ po, initialResults, why, canSeeCost }: { po: PoDetail; initialResults: PickableVariant[]; why: string | null; canSeeCost: boolean }) {
  const [search, searchAction] = useActionState(searchVariantsAction, { ...VARIANT_SEARCH_IDLE, results: initialResults });
  const [addState, addAction] = useActionState(upsertPoLinesAction, IDLE);
  const current = new Map(po.lines.map((l) => [l.variant_id, l]));
  return (
    <div className="space-y-4 rounded border border-border bg-background/60 p-4" data-testid="po-picker">
      <div>
        <h4 className="text-xs font-medium text-text-primary">Satır ekle</h4>
        <p className="mt-1 text-2xs leading-relaxed text-text-muted">
          Ürün adı, model kodu, SKU veya barkod ile arayın; ürün adı aratıldığında beden/renk serisinin tamamı listelenir. Adet girmediğiniz satırlar atlanır.
          {canSeeCost ? " Beklenen birim maliyet planlama içindir; gerçek maliyet mal kabulde girilir." : ""}
        </p>
        {why ? <p className="mt-2 rounded border border-border bg-surface px-3 py-2 text-xs text-text-secondary" data-testid="po-why">Analizden: {why}</p> : null}
      </div>
      <form action={searchAction} className="flex flex-wrap items-end gap-2">
        <div className="w-64">
          <Label htmlFor="po-term" className="sr-only">Varyant ara</Label>
          <Input id="po-term" name="term" defaultValue={search.term} placeholder="Ürün adı, model kodu, SKU veya barkod" className="h-11 sm:h-9" spellCheck={false} />
        </div>
        <Pending label="Ara" pendingLabel="Aranıyor…" />
      </form>
      {search.error ? <p role="alert" className="text-xs text-danger">{search.error}</p> : null}
      {search.results.length > 0 ? (
        <form action={addAction} className="space-y-3">
          <input type="hidden" name="po_id" value={po.id} />
          <ul className="divide-y divide-border border-y border-border">
            {search.results.map((v) => {
              const line = current.get(v.variant_id);
              return (
                <li key={v.variant_id} className="flex flex-wrap items-end gap-2 py-2.5" data-testid="po-pick-row">
                  <div className="min-w-[13rem] flex-1">
                    <span className="text-sm font-medium text-text-primary">{v.product_name}</span>
                    <span className="mt-0.5 block text-2xs text-text-muted">
                      {v.options} · <span data-numeric>{v.sku}</span>{v.primary_barcode ? <> · <span data-numeric>{v.primary_barcode}</span></> : null}
                      {line ? <span className="ml-1 text-accent">· siparişte {line.ordered}</span> : null}
                    </span>
                  </div>
                  <div className="w-20">
                    <Label htmlFor={`qty-${v.variant_id}`} className="text-2xs">Adet</Label>
                    <Input id={`qty-${v.variant_id}`} name={`qty_${v.variant_id}`} inputMode="numeric" defaultValue={line ? String(line.ordered) : ""} placeholder="—" className="h-11 text-right sm:h-9" />
                  </div>
                  {canSeeCost ? (
                    <div className="w-28">
                      <Label htmlFor={`cost-${v.variant_id}`} className="text-2xs">Beklenen maliyet</Label>
                      <Input id={`cost-${v.variant_id}`} name={`cost_${v.variant_id}`} inputMode="decimal" defaultValue={line?.expected_unit_cost != null ? moneyInputValue(line.expected_unit_cost) : ""} placeholder="0,00" className="h-11 text-right sm:h-9" />
                    </div>
                  ) : null}
                </li>
              );
            })}
          </ul>
          <FormMessage state={addState} successText="Satırlar kaydedildi." />
          <Pending label="Satırları kaydet" pendingLabel="Kaydediliyor…" variant="solid" testid="po-save-lines" />
        </form>
      ) : (
        <FormMessage state={addState} successText="Satırlar kaydedildi." />
      )}
    </div>
  );
}

export function RemoveLineButton({ poId, variantId }: { poId: string; variantId: string }) {
  const [state, formAction] = useActionState(removePoLineAction, IDLE);
  return (
    <form action={formAction} className="inline">
      <input type="hidden" name="po_id" value={poId} />
      <input type="hidden" name="variant_id" value={variantId} />
      <Pending label="Sil" pendingLabel="…" variant="ghost" />
      {state.error ? <span className="ml-2 text-2xs text-danger">{state.error}</span> : null}
    </form>
  );
}

export function PoActions({ po, caps, today }: { po: PoDetail; caps: ProcurementCaps; today: string }) {
  const [approve, approveAction] = useActionState(approvePoAction, IDLE);
  const [order, orderAction] = useActionState(orderPoAction, IDLE);
  const [cancel, cancelAction] = useActionState(cancelPoAction, IDLE);
  const [close, closeAction] = useActionState(closePoAction, IDLE);
  const [receipt, receiptAction] = useActionState(createReceiptFromPoAction, IDLE);
  const open = po.status === "ordered" || po.status === "partially_received";
  const state = [approve, order, cancel, close, receipt].find((s) => s.error) ?? IDLE;
  return (
    <section className="space-y-4 rounded border border-border-strong p-4" data-testid="po-actions">
      <h3 className="text-sm font-medium tracking-tightish">İşlemler</h3>
      <div className="flex flex-wrap gap-2">
        {caps.canManage && po.status === "draft" ? (
          <form action={approveAction}><input type="hidden" name="po_id" value={po.id} /><Pending label="Onayla" pendingLabel="Onaylanıyor…" variant="solid" testid="po-approve" /></form>
        ) : null}
        {caps.canManage && po.status === "approved" ? (
          <form action={orderAction}><input type="hidden" name="po_id" value={po.id} /><Pending label="Sipariş verildi olarak işaretle" pendingLabel="İşaretleniyor…" variant="solid" testid="po-order" /></form>
        ) : null}
        {caps.canReceive && open && po.totals.remaining > 0 ? (
          <form action={receiptAction} className="flex flex-wrap items-end gap-2">
            <input type="hidden" name="po_id" value={po.id} />
            <div className="w-40">
              <Label htmlFor="received_at" className="text-2xs">Teslim tarihi</Label>
              <Input id="received_at" name="received_at" type="date" defaultValue={today} className="h-9" />
            </div>
            <div className="w-40">
              <Label htmlFor="document_ref" className="text-2xs">İrsaliye / fatura no</Label>
              <Input id="document_ref" name="document_ref" className="h-9" maxLength={60} />
            </div>
            <Pending label="Mal kabul oluştur" pendingLabel="Oluşturuluyor…" variant="solid" testid="po-receipt" />
          </form>
        ) : null}
      </div>
      {caps.canReceive && open && po.totals.remaining > 0 ? (
        <p className="text-2xs text-text-muted">Taslak mal kabul, kalan adetlerle ve <strong>maliyetsiz</strong> açılır; teslim edilen gerçek adet ve birim maliyet mal kabul ekranında girilir. Stok, maliyet ve borç yalnız POST ile oluşur.</p>
      ) : null}
      {caps.canManage && (po.status === "draft" || po.status === "approved" || po.status === "ordered") ? (
        <form action={cancelAction} className="flex flex-wrap items-end gap-2">
          <input type="hidden" name="po_id" value={po.id} />
          <div className="w-64">
            <Label htmlFor="cancel_reason" className="text-2xs">İptal nedeni</Label>
            <Input id="cancel_reason" name="reason" className="h-9" maxLength={200} />
          </div>
          <Pending label="Siparişi iptal et" pendingLabel="İptal ediliyor…" testid="po-cancel" />
        </form>
      ) : null}
      {caps.canManage && (po.status === "partially_received" || po.status === "received") ? (
        <form action={closeAction} className="flex flex-wrap items-end gap-2">
          <input type="hidden" name="po_id" value={po.id} />
          {po.status === "partially_received" ? (
            <div className="w-64">
              <Label htmlFor="close_reason" className="text-2xs">Bekleyen {po.totals.remaining} adet neden gelmeyecek?</Label>
              <Input id="close_reason" name="reason" className="h-9" maxLength={200} />
            </div>
          ) : null}
          <Pending label={po.status === "partially_received" ? "Bekleyen miktarı kapat" : "Siparişi kapat"} pendingLabel="Kapatılıyor…" testid="po-close" />
        </form>
      ) : null}
      <FormMessage state={state} />
    </section>
  );
}

export function ExpectedTotal({ value, currency }: { value: number; currency: PoDetail["currency"] }) {
  return <span data-numeric>{formatMoney(value, currency)}</span>;
}
