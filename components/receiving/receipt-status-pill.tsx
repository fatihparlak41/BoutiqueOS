import { Badge, type BadgeProps } from "@/components/ui/badge";
import { RECEIPT_STATUS_LABELS, type ReceiptStatus } from "@/lib/receiving/model";

/** Reads the goods_receipt_status enum directly — draft / posted / cancelled. */
const TONE: Record<ReceiptStatus, BadgeProps["tone"]> = {
  draft: "olive",
  posted: "success",
  cancelled: "quiet",
};

export function ReceiptStatusPill({ status }: { status: ReceiptStatus }) {
  return (
    <Badge tone={TONE[status]} className={status === "cancelled" ? "line-through" : undefined}>
      {RECEIPT_STATUS_LABELS[status]}
    </Badge>
  );
}
