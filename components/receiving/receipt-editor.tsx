"use client";

import { useActionState, useState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { FormMessage } from "@/components/catalog/form-message";
import { IDLE } from "@/lib/catalog/action-state";
import {
  cancelReceiptAction,
  deleteReceiptLineAction,
  postReceiptAction,
  searchVariantsAction,
  updateReceiptHeaderAction,
  upsertReceiptLineAction,
} from "@/app/app/mal-kabul/actions";
import { VARIANT_SEARCH_IDLE, type ReceiptDetail, type ReceiptLine } from "@/lib/receiving/model";
import { formatMoney, formatQuantity, formatRate, moneyInputValue } from "@/lib/receiving/format";

/**
 * Draft workbench for a goods receipt.
 *
 * Everything here is draft-only. A posted receipt is rendered read-only by the page and
 * never reaches this component: no header edit, no line writes, no second post, and no
 * reversal — rpc_reverse_goods_receipt is an explicit NOT_IMPLEMENTED stub.
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

function HeaderForm({ receipt, fxHint }: { receipt: ReceiptDetail; fxHint: number | null }) {
  const [state, formAction] = useActionState(updateReceiptHeaderAction, IDLE);
  const isBase = receipt.invoice_currency === "TRY";

  return (
    <form action={formAction} className="space-y-4">
      <input type="hidden" name="receipt_id" value={receipt.id} />
      {/* Currency is fixed at creation; it is submitted so the server can re-apply the TRY rule. */}
      <input type="hidden" name="invoice_currency" value={receipt.invoice_currency} />

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className="space-y-1.5">
          <Label htmlFor="received_at">Alım tarihi</Label>
          <Input id="received_at" name="received_at" type="date" required defaultValue={receipt.received_at} className="h-9" />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="document_ref">Belge referansı</Label>
          <Input id="document_ref" name="document_ref" maxLength={80} defaultValue={receipt.document_ref ?? ""} className="h-9" spellCheck={false} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="exchange_rate">Kur (1 {receipt.invoice_currency} = ? TRY)</Label>
          <Input
            id="exchange_rate"
            name="exchange_rate"
            inputMode="decimal"
            defaultValue={isBase ? "1" : moneyInputValue(receipt.exchange_rate)}
            disabled={isBase}
            className="h-9"
          />
          {!isBase && fxHint !== null && Math.abs(fxHint - receipt.exchange_rate) > 0.000001 ? (
            <p className="text-2xs text-danger">
              Belge kuru günlük kurdan farklı (günlük: <span data-numeric>{formatRate(fxHint)}</span>).
            </p>
          ) : null}
        </div>
        <div className="space-y-1.5">
          <span className="block text-xs font-medium text-ink-70">Para birimi</span>
          <p className="pt-2 text-sm" data-numeric>
            {receipt.invoice_currency}
          </p>
          <p className="text-2xs text-muted">Oluşturulduktan sonra değiştirilmez.</p>
        </div>
        <div className="space-y-1.5 sm:col-span-2 lg:col-span-4">
          <Label htmlFor="note">Not</Label>
          <Textarea id="note" name="note" rows={2} defaultValue={receipt.note ?? ""} />
        </div>
      </div>

      <FormMessage state={state} successText="Belge başlığı kaydedildi." />
      <Pending label="Başlığı kaydet" pendingLabel="Kaydediliyor…" />
    </form>
  );
}

function LineRow({ receipt, line }: { receipt: ReceiptDetail; line: ReceiptLine }) {
  const [updateState, updateAction] = useActionState(upsertReceiptLineAction, IDLE);
  const [deleteState, deleteAction] = useActionState(deleteReceiptLineAction, IDLE);

  return (
    <>
      <tr className="align-top">
        <td className="py-2.5 pr-4">
          <span className="font-medium">{line.product_name}</span>
          <span className="mt-0.5 block text-2xs text-muted">{line.options}</span>
        </td>
        <td className="py-2.5 pr-4 text-ink-70" data-numeric>
          {line.sku}
          {line.primary_barcode ? (
            <span className="mt-0.5 block text-2xs text-muted">{line.primary_barcode}</span>
          ) : null}
        </td>
        <td className="py-2.5 pr-4">
          <form action={updateAction} className="flex flex-wrap items-end gap-2">
            <input type="hidden" name="receipt_id" value={receipt.id} />
            <input type="hidden" name="variant_id" value={line.variant_id} />
            <div className="w-20">
              <Label htmlFor={`qty-${line.id}`} className="sr-only">
                Adet
              </Label>
              <Input id={`qty-${line.id}`} name="quantity" inputMode="numeric" defaultValue={String(line.quantity)} className="h-9 text-right" />
            </div>
            <div className="w-28">
              <Label htmlFor={`cost-${line.id}`} className="sr-only">
                Birim maliyet
              </Label>
              <Input id={`cost-${line.id}`} name="unit_cost" inputMode="decimal" defaultValue={moneyInputValue(line.unit_cost)} className="h-9 text-right" />
            </div>
            <Pending label="Güncelle" pendingLabel="…" variant="ghost" />
          </form>
        </td>
        <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
          {formatMoney(line.quantity * line.unit_cost, receipt.invoice_currency)}
        </td>
        <td className="py-2.5 text-right">
          <form action={deleteAction}>
            <input type="hidden" name="receipt_id" value={receipt.id} />
            <input type="hidden" name="line_id" value={line.id} />
            <Pending label="Sil" pendingLabel="…" variant="ghost" />
          </form>
        </td>
      </tr>
      {updateState.error || deleteState.error ? (
        <tr>
          <td colSpan={5} className="pb-2">
            <FormMessage state={updateState.error ? updateState : deleteState} />
          </td>
        </tr>
      ) : null}
    </>
  );
}

function VariantPicker({ receipt }: { receipt: ReceiptDetail }) {
  const [search, searchAction] = useActionState(searchVariantsAction, VARIANT_SEARCH_IDLE);
  const [addState, addAction] = useActionState(upsertReceiptLineAction, IDLE);

  const existing = new Set(receipt.lines.map((line) => line.variant_id));

  return (
    <div className="space-y-4 border border-line bg-panel/40 p-4">
      <div>
        <h4 className="text-xs font-medium text-ink-70">Satır ekle</h4>
        <p className="mt-1 text-2xs text-muted">
          Ürün adı, SKU veya barkod ile arayın. Ürün adı aratıldığında o ürünün tüm aktif
          varyantları listelenir; beden serisini tek seferde girebilirsiniz.
        </p>
      </div>

      <form action={searchAction} className="flex flex-wrap items-end gap-2">
        <div className="w-64">
          <Label htmlFor="picker-term" className="sr-only">
            Varyant ara
          </Label>
          <Input id="picker-term" name="term" defaultValue={search.term} placeholder="Ürün adı, SKU veya barkod" className="h-9" spellCheck={false} />
        </div>
        <Pending label="Ara" pendingLabel="Aranıyor…" />
      </form>

      {search.error ? (
        <p role="alert" className="border-l-2 border-danger bg-panel px-3 py-2 text-xs text-danger">
          {search.error}
        </p>
      ) : null}

      {search.results.length > 0 ? (
        <ul className="divide-y divide-line border-y border-line">
          {search.results.map((variant) => (
            <li key={variant.variant_id} className="py-2.5">
              <form action={addAction} className="flex flex-wrap items-end gap-2">
                <input type="hidden" name="receipt_id" value={receipt.id} />
                <input type="hidden" name="variant_id" value={variant.variant_id} />
                <div className="min-w-[14rem] flex-1">
                  <span className="text-sm font-medium">{variant.product_name}</span>
                  <span className="mt-0.5 block text-2xs text-muted">
                    {variant.options} · <span data-numeric>{variant.sku}</span>
                    {variant.primary_barcode ? <> · <span data-numeric>{variant.primary_barcode}</span></> : null}
                  </span>
                </div>
                <div className="w-20">
                  <Label htmlFor={`new-qty-${variant.variant_id}`} className="text-2xs">
                    Adet
                  </Label>
                  <Input id={`new-qty-${variant.variant_id}`} name="quantity" inputMode="numeric" defaultValue="1" className="h-9 text-right" />
                </div>
                <div className="w-28">
                  <Label htmlFor={`new-cost-${variant.variant_id}`} className="text-2xs">
                    Birim maliyet
                  </Label>
                  <Input id={`new-cost-${variant.variant_id}`} name="unit_cost" inputMode="decimal" placeholder="0,00" className="h-9 text-right" />
                </div>
                <Pending label={existing.has(variant.variant_id) ? "Güncelle" : "Ekle"} pendingLabel="…" />
              </form>
            </li>
          ))}
        </ul>
      ) : null}

      <FormMessage state={addState} successText="Satır kaydedildi." />
    </div>
  );
}

function PostPanel({ receipt }: { receipt: ReceiptDetail }) {
  const [postState, postAction] = useActionState(postReceiptAction, IDLE);
  const [cancelState, cancelAction] = useActionState(cancelReceiptAction, IDLE);
  const [confirmed, setConfirmed] = useState(false);

  const totalQuantity = receipt.lines.reduce((sum, line) => sum + line.quantity, 0);
  const totalOriginal = receipt.lines.reduce((sum, line) => sum + line.quantity * line.unit_cost, 0);
  const totalBasePreview = totalOriginal * receipt.exchange_rate;
  const empty = receipt.lines.length === 0;

  return (
    <section className="space-y-4 border border-line-strong p-4">
      <h3 className="text-sm font-medium tracking-tightish">İşleme özeti</h3>

      <dl className="divide-y divide-line border-y border-line text-sm">
        {[
          ["Belge no", receipt.receipt_number],
          ["Tedarikçi", receipt.supplier_name],
          ["Şube", receipt.branch_name],
          ["Satır sayısı", String(receipt.lines.length)],
          ["Toplam adet", formatQuantity(totalQuantity)],
          ["Para birimi", receipt.invoice_currency],
          ["Belge tutarı", formatMoney(totalOriginal, receipt.invoice_currency)],
          ["Kur", formatRate(receipt.exchange_rate)],
          ["TRY karşılığı (önizleme)", formatMoney(totalBasePreview, "TRY")],
        ].map(([label, value]) => (
          <div key={label} className="flex justify-between gap-6 py-2">
            <dt className="text-muted">{label}</dt>
            <dd className="text-right" data-numeric>
              {value}
            </dd>
          </div>
        ))}
      </dl>

      <p className="text-2xs text-muted">
        TRY karşılığı burada önizlemedir. İşlendikten sonra geçerli olan değerler belgenin
        kendi alanlarından okunur.
      </p>

      <form action={postAction} className="space-y-3">
        <input type="hidden" name="receipt_id" value={receipt.id} />
        <label className="flex items-start gap-2 text-xs text-ink-70">
          <input
            type="checkbox"
            checked={confirmed}
            onChange={(event) => setConfirmed(event.target.checked)}
            className="mt-0.5 h-3.5 w-3.5 rounded-sm border-line-strong text-accent focus-visible:ring-2 focus-visible:ring-accent"
          />
          <span>
            Satırları ve tutarları kontrol ettim. İşlenen belge değiştirilemez ve geri alınamaz.
          </span>
        </label>
        <PostButton disabled={!confirmed || empty} />
        {empty ? <p className="text-2xs text-muted">Belgede satır yok; işlenemez.</p> : null}
      </form>

      <FormMessage state={postState} />

      <form action={cancelAction} className="border-t border-line pt-3">
        <input type="hidden" name="receipt_id" value={receipt.id} />
        <Pending label="Taslağı iptal et" pendingLabel="İptal ediliyor…" variant="ghost" />
        <p className="mt-1 text-2xs text-muted">
          Yalnız taslak belgeler iptal edilebilir; stoğa hiç dokunulmaz.
        </p>
      </form>
      <FormMessage state={cancelState} />
    </section>
  );
}

function PostButton({ disabled }: { disabled: boolean }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" disabled={disabled || pending}>
      {pending ? "İşleniyor…" : "Mal Kabulü İşle"}
    </Button>
  );
}

export function ReceiptEditor({ receipt, fxHint }: { receipt: ReceiptDetail; fxHint: number | null }) {
  return (
    <div className="space-y-10">
      <section className="space-y-4">
        <h3 className="text-sm font-medium tracking-tightish">Belge başlığı</h3>
        <HeaderForm receipt={receipt} fxHint={fxHint} />
      </section>

      <section className="space-y-4">
        <div>
          <h3 className="text-sm font-medium tracking-tightish">Satırlar</h3>
          <p className="mt-1 text-xs text-muted">
            Her varyant belgede yalnız bir kez bulunabilir. Aynı varyantı tekrar eklerseniz
            mevcut satır güncellenir.
          </p>
        </div>

        {receipt.lines.length === 0 ? (
          <p className="border border-dashed border-line-strong px-4 py-8 text-center text-xs text-muted">
            Henüz satır yok. Aşağıdan varyant arayıp ekleyin.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[46rem] border-collapse text-sm">
              <thead>
                <tr className="border-y border-line text-left text-xs text-muted">
                  <th scope="col" className="py-2 pr-4 font-medium">Ürün</th>
                  <th scope="col" className="py-2 pr-4 font-medium">SKU / barkod</th>
                  <th scope="col" className="py-2 pr-4 font-medium">Adet ve birim maliyet</th>
                  <th scope="col" className="py-2 pr-4 text-right font-medium">Satır tutarı</th>
                  <th scope="col" className="py-2 text-right font-medium">
                    <span className="sr-only">Sil</span>
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {receipt.lines.map((line) => (
                  <LineRow key={line.id} receipt={receipt} line={line} />
                ))}
              </tbody>
            </table>
          </div>
        )}

        <VariantPicker receipt={receipt} />
      </section>

      <PostPanel receipt={receipt} />
    </div>
  );
}
