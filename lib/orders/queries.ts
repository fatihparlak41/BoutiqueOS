import "server-only";

import { createClient } from "@/lib/supabase/server";
import { requireTenant } from "@/lib/tenant";
import type { OrderDetail, OrderFilter, OrderList } from "@/lib/orders/model";

/** Online order reads for the tenant. Each RPC proves the role in the database. */
export async function listOnlineOrders(status: OrderFilter | null, q: string | null, offset: number, limit: number): Promise<OrderList> {
  const { active } = await requireTenant();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rpc_online_orders", { p_business_id: active.business_id, p_status: status, p_q: q, p_limit: limit, p_offset: offset });
  if (error) throw new Error(`Online siparişler okunamadı: ${error.message}`);
  return data as OrderList;
}

export async function getOnlineOrder(orderId: string): Promise<OrderDetail | null> {
  const { active } = await requireTenant();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rpc_online_order_detail", { p_business_id: active.business_id, p_order_id: orderId });
  if (error) {
    if (/NOT_FOUND/.test(error.message)) return null;
    throw new Error(`Sipariş okunamadı: ${error.message}`);
  }
  return data as OrderDetail;
}

/** Materialises lapsed holds (what the reads already show). Called when the list opens; idempotent. */
export async function sweepOnlineOrders(): Promise<number> {
  const { active } = await requireTenant();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rpc_online_orders_sweep", { p_business_id: active.business_id });
  if (error) return 0;
  return Number((data as { expired?: number })?.expired ?? 0);
}
