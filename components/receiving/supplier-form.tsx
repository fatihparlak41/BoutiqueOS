"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { FormMessage } from "@/components/catalog/form-message";
import { IDLE, type ActionState } from "@/lib/catalog/action-state";
import { CURRENCIES, SUPPLIER_STATUS_LABELS, type Supplier } from "@/lib/receiving/model";

type SupplierAction = (state: ActionState, formData: FormData) => Promise<ActionState>;

function SubmitButton({ label, pendingLabel }: { label: string; pendingLabel: string }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="sm" disabled={pending}>
      {pending ? pendingLabel : label}
    </Button>
  );
}

/**
 * Only the columns that exist on `suppliers` are offered. `currency` uses the iso_currency
 * domain values and `status` the supplier_status enum — no invented fields.
 */
export function SupplierForm({
  action,
  supplier,
  submitLabel,
  pendingLabel,
  successText,
}: {
  action: SupplierAction;
  supplier?: Supplier;
  submitLabel: string;
  pendingLabel: string;
  successText?: string;
}) {
  const [state, formAction] = useActionState(action, IDLE);

  return (
    <form action={formAction} className="space-y-5" noValidate>
      {supplier ? <input type="hidden" name="supplier_id" value={supplier.id} /> : null}

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor={`name-${supplier?.id ?? "new"}`}>Tedarikçi adı</Label>
          <Input
            id={`name-${supplier?.id ?? "new"}`}
            name="name"
            required
            maxLength={120}
            defaultValue={supplier?.name ?? ""}
            autoFocus={!supplier}
            placeholder="Örn. Yerli Tekstil A.Ş."
          />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor={`code-${supplier?.id ?? "new"}`}>Kod</Label>
          <Input
            id={`code-${supplier?.id ?? "new"}`}
            name="code"
            maxLength={40}
            defaultValue={supplier?.code ?? ""}
            spellCheck={false}
          />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor={`currency-${supplier?.id ?? "new"}`}>Varsayılan para birimi</Label>
          <Select
            id={`currency-${supplier?.id ?? "new"}`}
            name="currency"
            defaultValue={supplier?.currency ?? "TRY"}
          >
            {CURRENCIES.map((currency) => (
              <option key={currency} value={currency}>
                {currency}
              </option>
            ))}
          </Select>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor={`status-${supplier?.id ?? "new"}`}>Durum</Label>
          <Select
            id={`status-${supplier?.id ?? "new"}`}
            name="status"
            defaultValue={supplier?.status ?? "active"}
          >
            {Object.entries(SUPPLIER_STATUS_LABELS).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </Select>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor={`contact-${supplier?.id ?? "new"}`}>Yetkili</Label>
          <Input
            id={`contact-${supplier?.id ?? "new"}`}
            name="contact_name"
            maxLength={80}
            defaultValue={supplier?.contact_name ?? ""}
          />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor={`phone-${supplier?.id ?? "new"}`}>Telefon</Label>
          <Input
            id={`phone-${supplier?.id ?? "new"}`}
            name="phone"
            maxLength={40}
            defaultValue={supplier?.phone ?? ""}
            spellCheck={false}
          />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor={`email-${supplier?.id ?? "new"}`}>E-posta</Label>
          <Input
            id={`email-${supplier?.id ?? "new"}`}
            name="email"
            type="email"
            maxLength={120}
            defaultValue={supplier?.email ?? ""}
            spellCheck={false}
          />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor={`city-${supplier?.id ?? "new"}`}>Şehir</Label>
          <Input
            id={`city-${supplier?.id ?? "new"}`}
            name="city"
            maxLength={60}
            defaultValue={supplier?.city ?? ""}
          />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor={`country-${supplier?.id ?? "new"}`}>Ülke kodu</Label>
          <Input
            id={`country-${supplier?.id ?? "new"}`}
            name="country"
            maxLength={2}
            defaultValue={supplier?.country ?? "TR"}
            spellCheck={false}
          />
        </div>

        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor={`notes-${supplier?.id ?? "new"}`}>Not</Label>
          <Textarea id={`notes-${supplier?.id ?? "new"}`} name="notes" rows={2} defaultValue={supplier?.notes ?? ""} />
        </div>
      </div>

      <FormMessage state={state} successText={successText} />

      <SubmitButton label={submitLabel} pendingLabel={pendingLabel} />
    </form>
  );
}
