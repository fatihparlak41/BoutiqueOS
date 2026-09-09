"use client";

import { useActionState, useState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { FormMessage } from "@/components/catalog/form-message";
import { IDLE } from "@/lib/catalog/action-state";
import { createReceiptAction } from "@/app/app/mal-kabul/actions";
import { CURRENCIES, type Currency, type Supplier } from "@/lib/receiving/model";
import { formatRate } from "@/lib/receiving/format";

type Branch = { id: string; name: string; code: string };
type FxHint = { currency: Currency; rate: number | null };

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" disabled={pending}>
      {pending ? "Taslak oluşturuluyor…" : "Taslak oluştur"}
    </Button>
  );
}

/**
 * Creates the draft through rpc_create_goods_receipt only. There is no receipt-number
 * field: the number is produced server-side by fn_next_sequence. There is no business_id
 * and no status field either — the RPC derives the tenant from the branch and always
 * writes a draft.
 */
export function ReceiptCreateForm({
  suppliers,
  branches,
  defaultBranchId,
  fxHints,
  today,
}: {
  suppliers: Supplier[];
  branches: Branch[];
  defaultBranchId: string | null;
  fxHints: FxHint[];
  today: string;
}) {
  const [state, formAction] = useActionState(createReceiptAction, IDLE);
  const [currency, setCurrency] = useState<Currency>("TRY");
  const [rate, setRate] = useState("");

  const hint = fxHints.find((h) => h.currency === currency)?.rate ?? null;
  const isBase = currency === "TRY";

  function handleCurrency(next: Currency) {
    setCurrency(next);
    if (next === "TRY") {
      setRate("");
      return;
    }
    const suggested = fxHints.find((h) => h.currency === next)?.rate ?? null;
    setRate(suggested === null ? "" : String(suggested).replace(".", ","));
  }

  function handleSupplier(supplierId: string) {
    const supplier = suppliers.find((s) => s.id === supplierId);
    if (supplier) handleCurrency(supplier.currency);
  }

  return (
    <form action={formAction} className="space-y-6" noValidate>
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="supplier_id">Tedarikçi</Label>
          <Select
            id="supplier_id"
            name="supplier_id"
            required
            defaultValue=""
            onChange={(event) => handleSupplier(event.target.value)}
          >
            <option value="" disabled>
              Seçin
            </option>
            {suppliers.map((supplier) => (
              <option key={supplier.id} value={supplier.id}>
                {supplier.name} ({supplier.currency})
              </option>
            ))}
          </Select>
          <p className="text-2xs text-muted">
            Yalnız aktif tedarikçiler kabul edilir; seçim para birimini ön doldurur.
          </p>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="branch_id">Şube</Label>
          <Select id="branch_id" name="branch_id" required defaultValue={defaultBranchId ?? ""}>
            {branches.map((branch) => (
              <option key={branch.id} value={branch.id}>
                {branch.name} ({branch.code})
              </option>
            ))}
          </Select>
          <p className="text-2xs text-muted">Stok bu şubeye girer. Sunucu şubeyi ayrıca doğrular.</p>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="document_ref">Belge / fatura referansı</Label>
          <Input id="document_ref" name="document_ref" maxLength={80} placeholder="Örn. FTR-2026-114" spellCheck={false} />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="received_at">Alım tarihi</Label>
          <Input id="received_at" name="received_at" type="date" required defaultValue={today} />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="invoice_currency">Para birimi</Label>
          <Select
            id="invoice_currency"
            name="invoice_currency"
            value={currency}
            onChange={(event) => handleCurrency(event.target.value as Currency)}
          >
            {CURRENCIES.map((c) => (
              <option key={c} value={c}>
                {c}
              </option>
            ))}
          </Select>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="exchange_rate">Kur (1 {currency} = ? TRY)</Label>
          <Input
            id="exchange_rate"
            name="exchange_rate"
            inputMode="decimal"
            value={isBase ? "1" : rate}
            onChange={(event) => setRate(event.target.value)}
            disabled={isBase}
            required={!isBase}
            placeholder="Örn. 42,50"
          />
          {isBase ? (
            <p className="text-2xs text-muted">TRY belgelerde kur her zaman 1&apos;dir.</p>
          ) : hint === null ? (
            <p className="text-2xs text-muted">
              Bu tarih için tanımlı kur yok. Belgede kullanılacak kuru siz girin.
            </p>
          ) : (
            <p className="text-2xs text-muted">
              Günlük kur: <span data-numeric>{formatRate(hint)}</span>. Bu yalnız öneridir; belgeye
              yazdığınız kur geçerli olandır.
            </p>
          )}
        </div>

        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="note">Not</Label>
          <Textarea id="note" name="note" rows={2} />
        </div>
      </div>

      <FormMessage state={state} />

      <SubmitButton />
    </form>
  );
}
