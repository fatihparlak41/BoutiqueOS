import type { UserRole } from "@/lib/roles";
import type { OnlineOrderStatus, PublicOrder } from "@/lib/shop/model";

/**
 * Merchant-side online order model (Phase 14B). rpc_online_orders / rpc_online_order_detail
 * return guest PII to the selling roles only (owner, manager, sales_staff); confirmation,
 * cancellation and re-reservation are owner/manager; "ready" and the POS conversion are
 * operational (selling roles). stock_staff has no order surface.
 */

export type OrderRow = {
  id: string;
  order_number: string;
  status: OnlineOrderStatus;
  public_status: OnlineOrderStatus;
  customer_name: string;
  phone: string;
  total: number;
  currency: string;
  item_count: number;
  created_at: string;
  reservation_expires_at: string | null;
  converted_sale_number: string | null;
};

export type OrderCounts = { new: number; confirmed: number; ready: number; completed: number; closed: number };
export type OrderList = { rows: OrderRow[]; total: number; limit: number; offset: number; counts: OrderCounts };

export type OrderDetail = PublicOrder & {
  id: string;
  phone_normalized: string;
  branch_id: string;
  reservation: { id: string; reservation_number: string; status: string; expires_at: string; active: boolean } | null;
  converted_sale: { id: string; sale_number: string; total: number; occurred_at: string } | null;
  cancel_reason: string | null;
  actors: { confirmed_by: string | null; ready_by: string | null; cancelled_by: string | null };
  items_live: Array<{ variant_id: string; quantity: number; unit_price: number; list_price_now: number; available_now: number; sku: string }>;
  events: Array<{ event: string; at: string; actor_type: "customer" | "tenant" | "system"; actor: string | null; payload: Record<string, unknown> }>;
};

export const ORDER_FILTERS = ["new", "confirmed", "ready", "completed", "closed"] as const;
export type OrderFilter = (typeof ORDER_FILTERS)[number];
export const ORDER_FILTER_LABELS: Record<OrderFilter, string> = { new: "Yeni", confirmed: "Onaylı", ready: "Hazır", completed: "Teslim edildi", closed: "İptal / süresi doldu" };

export const EVENT_LABELS: Record<string, string> = {
  created: "Sipariş talebi alındı",
  confirmed: "Onaylandı",
  ready: "Teslime hazır",
  cancelled: "İptal edildi",
  expired: "Ayırma süresi doldu",
  rereserved: "Yeniden ayrıldı",
  converted: "POS satışına dönüştü",
  completed: "Teslim edildi",
};

export function orderCaps(role: UserRole) {
  const selling = role === "owner" || role === "manager" || role === "sales_staff";
  const manage = role === "owner" || role === "manager";
  return { canView: selling, canConfirm: manage, canCancel: manage, canRereserve: manage, canReady: selling, canConvert: selling };
}

export type OrderActionState = { error: string | null; ok: boolean; message?: string };
export const ORDER_IDLE: OrderActionState = { error: null, ok: false };
