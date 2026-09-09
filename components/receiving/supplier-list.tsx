"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { SupplierForm } from "@/components/receiving/supplier-form";
import { updateSupplierAction } from "@/app/app/tedarikciler/actions";
import { SUPPLIER_STATUS_LABELS, type Supplier } from "@/lib/receiving/model";
import { cn } from "@/lib/utils";

/** Editing happens inline so the module keeps the two routes it was scoped to. */
function SupplierRow({ supplier, canEdit }: { supplier: Supplier; canEdit: boolean }) {
  const [open, setOpen] = useState(false);

  return (
    <>
      <tr className="align-top transition-colors hover:bg-panel/60">
        <td className="py-2.5 pr-4">
          <span className="font-medium">{supplier.name}</span>
          {supplier.code ? (
            <span className="mt-0.5 block text-2xs text-muted" data-numeric>
              {supplier.code}
            </span>
          ) : null}
        </td>
        <td className="py-2.5 pr-4 text-ink-70" data-numeric>
          {supplier.currency}
        </td>
        <td className="py-2.5 pr-4 text-ink-70">{supplier.contact_name ?? "—"}</td>
        <td className="py-2.5 pr-4 text-ink-70" data-numeric>
          {supplier.phone ?? "—"}
        </td>
        <td className="py-2.5 pr-4">
          <span
            className={cn(
              "inline-flex whitespace-nowrap rounded-sm border px-1.5 py-0.5 text-2xs font-medium",
              supplier.status === "active"
                ? "border-accent/30 bg-accent-soft text-accent"
                : "border-line-strong bg-transparent text-muted",
            )}
          >
            {SUPPLIER_STATUS_LABELS[supplier.status]}
          </span>
        </td>
        <td className="py-2.5 text-right">
          {canEdit ? (
            <Button
              type="button"
              size="sm"
              variant="ghost"
              aria-expanded={open}
              onClick={() => setOpen((v) => !v)}
            >
              {open ? "Kapat" : "Düzenle"}
            </Button>
          ) : null}
        </td>
      </tr>

      {open && canEdit ? (
        <tr>
          <td colSpan={6} className="border-t border-line bg-panel/30 px-3 py-4">
            <SupplierForm
              action={updateSupplierAction}
              supplier={supplier}
              submitLabel="Kaydet"
              pendingLabel="Kaydediliyor…"
              successText="Tedarikçi güncellendi."
            />
          </td>
        </tr>
      ) : null}
    </>
  );
}

export function SupplierList({ suppliers, canEdit }: { suppliers: Supplier[]; canEdit: boolean }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[42rem] border-collapse text-sm">
        <thead>
          <tr className="border-y border-line text-left text-xs text-muted">
            <th scope="col" className="py-2 pr-4 font-medium">Tedarikçi</th>
            <th scope="col" className="py-2 pr-4 font-medium">Para birimi</th>
            <th scope="col" className="py-2 pr-4 font-medium">Yetkili</th>
            <th scope="col" className="py-2 pr-4 font-medium">Telefon</th>
            <th scope="col" className="py-2 pr-4 font-medium">Durum</th>
            <th scope="col" className="py-2 text-right font-medium">
              <span className="sr-only">İşlem</span>
            </th>
          </tr>
        </thead>
        <tbody className="divide-y divide-line">
          {suppliers.map((supplier) => (
            <SupplierRow key={supplier.id} supplier={supplier} canEdit={canEdit} />
          ))}
        </tbody>
      </table>
    </div>
  );
}
