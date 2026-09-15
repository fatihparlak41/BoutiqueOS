"use client";

import { useMemo } from "react";
import { Badge } from "@/components/ui/badge";
import { ProductThumb } from "@/components/catalog/product-thumb";
import { BUCKET_LABELS, type Bucket } from "@/lib/stock/model";
import { COUNT_STATUS_LABELS, type CountVariant, type StockCountStatus } from "@/lib/stock/count-model";
import type { CountEvent } from "@/app/app/stok/sayim/actions";
import { cn } from "@/lib/utils";

/** Condition colours are meaning: green sells, amber waits, red is damaged. */
export const BUCKET_TONE: Record<Bucket, "success" | "warning" | "danger"> = {
  sellable: "success",
  quarantine: "warning",
  damaged: "danger",
};

export function ConditionBadge({ bucket }: { bucket: Bucket }) {
  return <Badge tone={BUCKET_TONE[bucket]}>{BUCKET_LABELS[bucket]}</Badge>;
}

export function StatusBadge({ status }: { status: StockCountStatus }) {
  const tone = status === "posted" ? "success" : status === "review" ? "accent" : status === "cancelled" ? "quiet" : status === "counting" ? "olive" : "neutral";
  return <Badge tone={tone}>{COUNT_STATUS_LABELS[status]}</Badge>;
}

/** Product line the operator recognises at a glance: thumb, name, colour / size, SKU. */
export function VariantIdentity({ v, size = "md", className }: { v: CountVariant; size?: "sm" | "md"; className?: string }) {
  return (
    <div className={cn("flex min-w-0 items-center gap-3", className)}>
      <ProductThumb url={v.thumbnail_url} alt={v.product_name} size={size} />
      <div className="min-w-0">
        <p className="truncate text-sm font-medium text-text-primary">{v.product_name}</p>
        <p className="truncate text-xs text-text-secondary">{v.options || "Tek varyant"}</p>
        <p className="truncate text-2xs text-text-muted" data-numeric>
          {v.sku}
          {v.primary_barcode ? ` · ${v.primary_barcode}` : ""}
        </p>
      </div>
    </div>
  );
}

/** Difference with its sign, coloured; "—" while unknown. */
export function Difference({ value }: { value: number | null }) {
  if (value === null) return <span className="text-text-muted">—</span>;
  const cls = value > 0 ? "text-success" : value < 0 ? "text-danger" : "text-text-muted";
  return (
    <span className={cn("font-medium", cls)} data-numeric>
      {value > 0 ? `+${value}` : value}
    </span>
  );
}

/**
 * Every counting call carries a fresh client transaction id, the device id this browser
 * was given once, and the client clock. The server ignores a replayed id, so a retried
 * request never counts twice.
 */
export function useCountEvents() {
  const deviceId = useMemo(() => {
    try {
      const key = "boutiqueos.count.device";
      let id = window.localStorage.getItem(key);
      if (!id) {
        id = crypto.randomUUID();
        window.localStorage.setItem(key, id);
      }
      return id;
    } catch {
      return null;
    }
  }, []);
  return (): CountEvent => ({ client_tx: crypto.randomUUID(), device_id: deviceId, client_at: new Date().toISOString() });
}
