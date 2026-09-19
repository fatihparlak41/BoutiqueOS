import { Badge } from "@/components/ui/badge";
import type { OnlineOrderStatus } from "@/lib/shop/model";
import { MERCHANT_STATUS_LABELS } from "@/lib/orders/model";

export function OrderPill({ status }: { status: OnlineOrderStatus }) {
  const tone = status === "pending_confirmation" ? "accent" : status === "confirmed" ? "olive" : status === "ready" ? "success" : status === "completed" ? "neutral" : status === "expired" ? "warning" : "quiet";
  return <Badge tone={tone}>{MERCHANT_STATUS_LABELS[status]}</Badge>;
}

const dateTime = new Intl.DateTimeFormat("tr-TR", { dateStyle: "medium", timeStyle: "short" });
export function fmtDateTime(iso: string | null | undefined): string {
  return iso ? dateTime.format(new Date(iso)) : "—";
}
