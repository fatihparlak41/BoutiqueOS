"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { IDLE } from "@/lib/catalog/action-state";
import type { ProductStatus } from "@/lib/catalog/model";
import { archiveProductAction } from "@/app/app/urunler/actions";

function Pending({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="sm" variant="outline" disabled={pending}>
      {pending ? "…" : label}
    </Button>
  );
}

/** Archive / restore. There is no delete: sales, receipts and stock history point here. */
export function ArchiveToggle({ productId, status }: { productId: string; status: ProductStatus }) {
  const [state, formAction] = useActionState(archiveProductAction, IDLE);
  const archived = status === "archived";

  return (
    <form action={formAction} className="flex items-center gap-2">
      <input type="hidden" name="product_id" value={productId} />
      <input type="hidden" name="status" value={archived ? "active" : "archived"} />
      {state.error ? <span className="text-xs text-danger">{state.error}</span> : null}
      <Pending label={archived ? "Arşivden çıkar" : "Arşivle"} />
    </form>
  );
}
