import { Badge, type BadgeProps } from "@/components/ui/badge";
import {
  PRODUCT_STATUS_LABELS,
  VARIANT_STATUS_LABELS,
  type ProductStatus,
  type VariantStatus,
} from "@/lib/catalog/model";

/** Tone is the state's meaning: active sells, a draft is work in progress, an archive is inert. */
const TONE: Record<ProductStatus | VariantStatus, BadgeProps["tone"]> = {
  active: "success",
  draft: "olive",
  archived: "quiet",
};

/** Reads the status straight from the enum the database defines — no invented booleans. */
export function StatusPill({ status }: { status: ProductStatus | VariantStatus }) {
  const label =
    status in PRODUCT_STATUS_LABELS
      ? PRODUCT_STATUS_LABELS[status as ProductStatus]
      : VARIANT_STATUS_LABELS[status as VariantStatus];

  return <Badge tone={TONE[status]}>{label}</Badge>;
}
