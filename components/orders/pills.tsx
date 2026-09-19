import { Badge } from "@/components/ui/badge";
import { ORDER_STATUS_LABELS, type OnlineOrderStatus } from "@/lib/shop/model";

export function OrderPill({ status }: { status: OnlineOrderStatus }) {
  const tone = status === "pending_confirmation" ? "accent" : status === "confirmed" ? "success" : status === "ready" ? "success" : status === "completed" ? "neutral" : status === "expired" ? "warning" : "neutral";
  return <Badge tone={tone}>{ORDER_STATUS_LABELS[status]}</Badge>;
}

const dateTime = new Intl.DateTimeFormat("tr-TR", { dateStyle: "medium", timeStyle: "short" });
export function fmtDateTime(iso: string | null | undefined): string {
  return iso ? dateTime.format(new Date(iso)) : "—";
}
