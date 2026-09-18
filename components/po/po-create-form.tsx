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
import { createPoAction } from "@/app/app/satin-alma/actions";
import { CURRENCIES, type Currency, type Supplier } from "@/lib/receiving/model";

type Branch = { id: string; name: string; code: string };

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" disabled={pending} data-testid="po-create">
      {pending ? "Taslak oluşturuluyor…" : "Taslak oluştur"}
    </Button>
  );
}

/**
 * Creates the draft through rpc_po_create only: the number comes from the server, the
 * tenant from the branch, the status is always draft. The optional prefill (from the
 * intelligence page) is carried through and added on the detail page — never ordered.
 */
export function PoCreateForm({
  suppliers, branches, defaultBranchId, today, prefill,
}: {
  suppliers: Supplier[];
  branches: Branch[];
  defaultBranchId: string | null;
  today: string;
  prefill: { variantId: string; why: string | null; label: string | null } | null;
}) {
  const [state, formAction] = useActionState(createPoAction, IDLE);
  const [currency, setCurrency] = useState<Currency>("TRY");
  const isBase = currency === "TRY";

  return (
    <form action={formAction} className="max-w-2xl space-y-6" data-testid="po-create-form">
      {prefill ? (
        <div className="rounded border border-border bg-background/60 px-4 py-3 text-xs">
          <p className="font-medium text-text-primary">Analizden gelen aday: {prefill.label ?? "seçili varyant"}</p>
          {prefill.why ? <p className="mt-1 text-text-muted">{prefill.why}</p> : null}
          <p className="mt-1 text-text-muted">Taslak açıldığında bu varyant satır seçicide hazır olur; adedi siz girersiniz.</p>
          <input type="hidden" name="prefill_variant" value={prefill.variantId} />
          {prefill.why ? <input type="hidden" name="prefill_why" value={prefill.why} /> : null}
        </div>
      ) : null}
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="supplier_id">Tedarikçi</Label>
          <Select id="supplier_id" name="supplier_id" required defaultValue="">
            <option value="" disabled>Seçin</option>
            {suppliers.map((s) => (
              <option key={s.id} value={s.id}>{s.name}{s.currency !== "TRY" ? ` (${s.currency})` : ""}</option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="branch_id">Şube</Label>
          <Select id="branch_id" name="branch_id" required defaultValue={defaultBranchId ?? ""}>
            {branches.map((b) => (
              <option key={b.id} value={b.id}>{b.name}</option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="currency">Sipariş para birimi</Label>
          <Select id="currency" name="currency" value={currency} onChange={(e) => setCurrency(e.target.value as Currency)}>
            {CURRENCIES.map((c) => (
              <option key={c} value={c}>{c}</option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="fx_rate">Bilgi amaçlı kur {isBase ? "(TRY: 1)" : "(1 birim = ? TRY)"}</Label>
          <Input id="fx_rate" name="fx_rate" inputMode="decimal" placeholder={isBase ? "1" : "örn. 35,50"} disabled={isBase} />
          {!isBase ? <p className="text-2xs text-text-muted">Muhasebe kuru değildir; mal kabul kendi kurunu alır.</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="order_date">Sipariş tarihi</Label>
          <Input id="order_date" name="order_date" type="date" defaultValue={today} required />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="expected_date">Beklenen teslim (isteğe bağlı)</Label>
          <Input id="expected_date" name="expected_date" type="date" />
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="supplier_reference">Tedarikçi referansı (isteğe bağlı)</Label>
          <Input id="supplier_reference" name="supplier_reference" maxLength={80} />
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="note">Not</Label>
          <Textarea id="note" name="note" rows={2} maxLength={500} />
        </div>
      </div>
      <FormMessage state={state} />
      <SubmitButton />
    </form>
  );
}
