"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { FormMessage } from "@/components/catalog/form-message";
import type { VariantRow } from "@/lib/catalog/model";
import { IDLE } from "@/lib/catalog/action-state";
import {
  addBarcodeAction,
  deleteBarcodeAction,
  generateInternalBarcodeAction,
  setPrimaryBarcodeAction,
} from "@/app/app/urunler/actions";

/**
 * A variant can carry several barcodes: the supplier's printed EAN plus an internal
 * Code128 the shop prints itself. Exactly one of them is primary — the database enforces
 * that with a partial unique index, so the UI only has to offer the choice.
 */

const BARCODE_TYPE_LABELS: Record<VariantRow["barcodes"][number]["barcode_type"], string> = {
  internal: "Dahili",
  supplier: "Tedarikçi",
};

function PendingButton({
  label,
  pendingLabel,
  variant = "outline",
}: {
  label: string;
  pendingLabel: string;
  variant?: "solid" | "outline" | "ghost";
}) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {pending ? pendingLabel : label}
    </Button>
  );
}

export function BarcodePanel({
  productId,
  variant,
  canManage,
}: {
  productId: string;
  variant: VariantRow;
  canManage: boolean;
}) {
  const [addState, addAction] = useActionState(addBarcodeAction, IDLE);
  const [internalState, internalAction] = useActionState(generateInternalBarcodeAction, IDLE);
  const [primaryState, primaryAction] = useActionState(setPrimaryBarcodeAction, IDLE);
  const [deleteState, deleteAction] = useActionState(deleteBarcodeAction, IDLE);

  const hasPrimary = variant.barcodes.some((barcode) => barcode.is_primary);

  return (
    <div className="space-y-3">
      <h5 className="text-xs font-medium text-ink-70">Barkodlar</h5>

      {variant.barcodes.length === 0 ? (
        <p className="text-2xs text-muted">Bu varyantın barkodu yok.</p>
      ) : (
        <ul className="divide-y divide-line border-y border-line">
          {variant.barcodes.map((barcode) => (
            <li key={barcode.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-2">
              <span className="text-sm" data-numeric>
                {barcode.barcode}
              </span>
              <span className="text-2xs text-muted">
                {BARCODE_TYPE_LABELS[barcode.barcode_type]} · {barcode.symbology}
              </span>
              {barcode.is_primary ? (
                <span className="rounded-sm border border-accent/30 bg-accent-soft px-1.5 py-0.5 text-2xs font-medium text-accent">
                  Birincil
                </span>
              ) : null}

              {canManage ? (
                <span className="ml-auto flex items-center gap-2">
                  {barcode.is_primary ? null : (
                    <form action={primaryAction}>
                      <input type="hidden" name="barcode_id" value={barcode.id} />
                      <input type="hidden" name="variant_id" value={variant.id} />
                      <input type="hidden" name="product_id" value={productId} />
                      <PendingButton label="Birincil yap" pendingLabel="…" variant="ghost" />
                    </form>
                  )}
                  <form action={deleteAction}>
                    <input type="hidden" name="barcode_id" value={barcode.id} />
                    <input type="hidden" name="product_id" value={productId} />
                    <PendingButton label="Sil" pendingLabel="…" variant="ghost" />
                  </form>
                </span>
              ) : null}
            </li>
          ))}
        </ul>
      )}

      <FormMessage state={primaryState} />
      <FormMessage state={deleteState} />

      {canManage ? (
        <div className="space-y-4 pt-1">
          <form action={addAction} className="grid gap-3 sm:grid-cols-[1fr_9rem_auto] sm:items-end">
            <div className="space-y-1.5">
              <Label htmlFor={`barcode-${variant.id}`}>Mevcut barkod ekle</Label>
              <Input
                id={`barcode-${variant.id}`}
                name="barcode"
                required
                minLength={3}
                maxLength={64}
                spellCheck={false}
                inputMode="numeric"
                placeholder="Etiketteki barkod"
                className="h-9"
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor={`symbology-${variant.id}`}>Tip</Label>
              <Select id={`symbology-${variant.id}`} name="symbology" defaultValue="EAN13" className="h-9">
                <option value="EAN13">EAN13</option>
                <option value="CODE128">CODE128</option>
              </Select>
            </div>
            <div className="flex flex-col gap-2">
              <label className="flex items-center gap-2 text-2xs text-ink-70">
                <input
                  type="checkbox"
                  name="is_primary"
                  defaultChecked={!hasPrimary}
                  className="h-3.5 w-3.5 rounded-sm border-line-strong text-accent focus-visible:ring-2 focus-visible:ring-accent"
                />
                Birincil
              </label>
              <input type="hidden" name="variant_id" value={variant.id} />
              <input type="hidden" name="product_id" value={productId} />
              <PendingButton label="Barkod ekle" pendingLabel="Ekleniyor…" />
            </div>
          </form>

          <FormMessage state={addState} successText="Barkod eklendi." />

          <form action={internalAction} className="flex flex-wrap items-center gap-3 border-t border-line pt-3">
            <input type="hidden" name="variant_id" value={variant.id} />
            <input type="hidden" name="product_id" value={productId} />
            <label className="flex items-center gap-2 text-2xs text-ink-70">
              <input
                type="checkbox"
                name="make_primary"
                defaultChecked={!hasPrimary}
                className="h-3.5 w-3.5 rounded-sm border-line-strong text-accent focus-visible:ring-2 focus-visible:ring-accent"
              />
              Birincil yap
            </label>
            <PendingButton label="Dahili barkod üret" pendingLabel="Üretiliyor…" />
            <span className="text-2xs text-muted">
              Etiketi olmayan ürünler için işletmeye özel Code128 üretir.
            </span>
          </form>

          <FormMessage state={internalState} successText="Dahili barkod üretildi." />
        </div>
      ) : null}
    </div>
  );
}
