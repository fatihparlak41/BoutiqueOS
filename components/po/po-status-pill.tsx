import { Badge, type BadgeProps } from "@/components/ui/badge";
import { PO_STATUS_LABELS, type PoStatus } from "@/lib/po/model";

const TONE: Record<PoStatus, BadgeProps["tone"]> = {
  draft: "olive",
  approved: "accent",
  ordered: "accent",
  partially_received: "warning",
  received: "success",
  closed: "neutral",
  cancelled: "quiet",
};

export function PoStatusPill({ status }: { status: PoStatus }) {
  return (
    <Badge tone={TONE[status]} className={status === "cancelled" ? "line-through" : undefined}>
      {PO_STATUS_LABELS[status]}
    </Badge>
  );
}
