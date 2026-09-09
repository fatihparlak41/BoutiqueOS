import { cn } from "@/lib/utils";
import {
  PRODUCT_STATUS_LABELS,
  VARIANT_STATUS_LABELS,
  type ProductStatus,
  type VariantStatus,
} from "@/lib/catalog/model";

const TONE: Record<ProductStatus | VariantStatus, string> = {
  active: "border-accent/30 bg-accent-soft text-accent",
  draft: "border-line-strong bg-panel text-ink-70",
  archived: "border-line-strong bg-transparent text-muted",
};

/** Reads the status straight from the enum the database defines — no invented booleans. */
export function StatusPill({ status }: { status: ProductStatus | VariantStatus }) {
  const label =
    status in PRODUCT_STATUS_LABELS
      ? PRODUCT_STATUS_LABELS[status as ProductStatus]
      : VARIANT_STATUS_LABELS[status as VariantStatus];

  return (
    <span
      className={cn(
        "inline-flex items-center whitespace-nowrap rounded-sm border px-1.5 py-0.5 text-2xs font-medium",
        TONE[status],
      )}
    >
      {label}
    </span>
  );
}
