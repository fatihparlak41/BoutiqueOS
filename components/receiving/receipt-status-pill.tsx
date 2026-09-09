import { cn } from "@/lib/utils";
import { RECEIPT_STATUS_LABELS, type ReceiptStatus } from "@/lib/receiving/model";

/** Reads the goods_receipt_status enum directly — draft / posted / cancelled. */
const TONE: Record<ReceiptStatus, string> = {
  draft: "border-line-strong bg-panel text-ink-70",
  posted: "border-accent/30 bg-accent-soft text-accent",
  cancelled: "border-line-strong bg-transparent text-muted line-through",
};

export function ReceiptStatusPill({ status }: { status: ReceiptStatus }) {
  return (
    <span
      className={cn(
        "inline-flex items-center whitespace-nowrap rounded-sm border px-1.5 py-0.5 text-2xs font-medium",
        TONE[status],
      )}
    >
      {RECEIPT_STATUS_LABELS[status]}
    </span>
  );
}
