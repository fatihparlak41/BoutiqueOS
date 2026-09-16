import "server-only";

import { loadPosContext } from "@/lib/pos/queries";
import type { Eligibility, FoundSale, LookupMode, ReturnDocument } from "@/lib/pos/returns-model";

/**
 * Read side of returns / exchange. Three SECURITY DEFINER reads, all role-checked in the
 * database (owner / manager / sales_staff): the sale lookup, the per-line eligibility and
 * the return document. None of them returns cost.
 */

function num(value: unknown): number {
  const n = typeof value === "number" ? value : Number(value);
  return Number.isFinite(n) ? n : 0;
}

export async function findSales(mode: LookupMode, query: string): Promise<FoundSale[]> {
  const { supabase, businessId } = await loadPosContext();
  const { data, error } = await supabase.rpc("rpc_pos_find_sales", { p_business_id: businessId, p_mode: mode, p_query: query.trim().slice(0, 80) });
  if (error) throw new Error(`Satış aranamadı: ${error.message}`);
  const rows = (Array.isArray(data) ? data : []) as Array<Record<string, unknown>>;
  return rows.map((r) => ({
    id: String(r.id),
    sale_number: String(r.sale_number),
    status: r.status as "completed" | "voided",
    occurred_at: String(r.occurred_at),
    total: num(r.total),
    branch_id: String(r.branch_id),
    customer_name: (r.customer_name as string | null) ?? null,
    customer_phone: (r.customer_phone as string | null) ?? null,
    item_count: num(r.item_count),
    returned_count: num(r.returned_count),
    is_exchange_replacement: Boolean(r.is_exchange_replacement),
  }));
}

export async function getEligibility(saleId: string): Promise<Eligibility | null> {
  const { supabase } = await loadPosContext();
  const { data, error } = await supabase.rpc("rpc_return_eligibility", { p_sale_id: saleId });
  if (error) {
    if (/NOT_FOUND/.test(error.message)) return null;
    throw new Error(`Uygunluk okunamadı: ${error.message}`);
  }
  const e = (data ?? {}) as Record<string, unknown>;
  const sale = (e.sale ?? {}) as Record<string, unknown>;
  const policy = (e.policy ?? {}) as Record<string, unknown>;
  return {
    sale: {
      id: String(sale.id),
      sale_number: String(sale.sale_number),
      status: sale.status as "completed" | "voided",
      occurred_at: String(sale.occurred_at),
      branch_id: String(sale.branch_id),
      branch_name: String(sale.branch_name ?? "—"),
      total: num(sale.total),
      customer_id: (sale.customer_id as string | null) ?? null,
      customer_name: (sale.customer_name as string | null) ?? null,
      customer_phone: (sale.customer_phone as string | null) ?? null,
      exchange_group_id: (sale.exchange_group_id as string | null) ?? null,
    },
    policy: {
      allow_exchange: Boolean(policy.allow_exchange),
      allow_cash_refund: Boolean(policy.allow_cash_refund),
      allow_store_credit: Boolean(policy.allow_store_credit),
      exchange_window_days: num(policy.exchange_window_days),
      receipt_required: Boolean(policy.receipt_required),
      reason_required: Boolean(policy.reason_required),
      downgrade_treatment: (policy.downgrade_treatment as "block" | "cash_refund" | "store_credit") ?? "block",
      window_expired: Boolean(policy.window_expired),
      days_left: num(policy.days_left),
    },
    returns: ((e.returns ?? []) as Array<Record<string, unknown>>).map((r) => ({
      id: String(r.id), return_number: String(r.return_number), return_type: r.return_type as "exchange" | "refund" | "store_credit",
      credit_value_base: num(r.credit_value_base), refund_amount_base: num(r.refund_amount_base), created_at: String(r.created_at),
      replacement_sale_id: (r.replacement_sale_id as string | null) ?? null,
    })),
    reasons: ((e.reasons ?? []) as Array<Record<string, unknown>>).map((r) => ({ code: String(r.code), label: String(r.label) })),
    lines: ((e.lines ?? []) as Array<Record<string, unknown>>).map((l) => ({
      sale_item_id: String(l.sale_item_id), variant_id: String(l.variant_id), sku: String(l.sku), product_name: String(l.product_name),
      options: (l.options as string | null) ?? null, quantity: num(l.quantity), returned_quantity: num(l.returned_quantity),
      returnable_quantity: num(l.returnable_quantity), unit_price_at_sale: num(l.unit_price_at_sale), list_price: num(l.list_price),
      status: l.status as Eligibility["lines"][number]["status"], excluded_by: (l.excluded_by as "product" | "category" | null) ?? null,
    })),
  };
}

export async function getReturnDocument(returnId: string): Promise<ReturnDocument | null> {
  const { supabase } = await loadPosContext();
  const { data, error } = await supabase.rpc("rpc_return_document", { p_return_id: returnId });
  if (error) throw new Error(`İade belgesi okunamadı: ${error.message}`);
  if (!data) return null;
  const d = data as Record<string, unknown>;
  const c = d.customer as Record<string, unknown> | null;
  return {
    id: String(d.id), return_number: String(d.return_number), return_type: d.return_type as ReturnDocument["return_type"], created_at: String(d.created_at),
    original_sale_id: String(d.original_sale_id), original_sale_number: String(d.original_sale_number),
    replacement_sale_id: (d.replacement_sale_id as string | null) ?? null, replacement_sale_number: (d.replacement_sale_number as string | null) ?? null,
    credit_value_base: num(d.credit_value_base), refund_amount_base: num(d.refund_amount_base),
    refund_method: (d.refund_method as ReturnDocument["refund_method"]) ?? null,
    reason_code: (d.reason_code as string | null) ?? null, reason_label: (d.reason_label as string | null) ?? null,
    note: (d.note as string | null) ?? null, processed_by_name: (d.processed_by_name as string | null) ?? null, branch_name: String(d.branch_name ?? "—"),
    customer: c ? { id: String(c.id), full_name: (c.full_name as string | null) ?? null, phone: String(c.phone) } : null,
    items: ((d.items ?? []) as Array<Record<string, unknown>>).map((i) => ({
      id: String(i.id), variant_id: String(i.variant_id), sku: String(i.sku), product_name: String(i.product_name),
      quantity: num(i.quantity), disposition: i.disposition as ReturnDocument["items"][number]["disposition"], unit_price_at_sale: num(i.unit_price_at_sale),
    })),
  };
}

/** Returns raised against a sale (for the receipt screen); RLS-scoped like the sale itself. */
export async function listReturnsOfSale(saleId: string): Promise<Array<{ id: string; return_number: string; return_type: string; credit_value_base: number; refund_amount_base: number; replacement_sale_id: string | null; created_at: string }>> {
  const { supabase, businessId } = await loadPosContext();
  const { data, error } = await supabase
    .from("returns")
    .select("id, return_number, return_type, credit_value_base, refund_amount_base, replacement_sale_id, created_at")
    .eq("business_id", businessId)
    .eq("original_sale_id", saleId)
    .order("created_at");
  if (error) throw new Error(`İadeler okunamadı: ${error.message}`);
  return (data ?? []).map((r) => ({
    id: r.id as string, return_number: r.return_number as string, return_type: r.return_type as string,
    credit_value_base: num(r.credit_value_base), refund_amount_base: num(r.refund_amount_base),
    replacement_sale_id: (r.replacement_sale_id as string | null) ?? null, created_at: r.created_at as string,
  }));
}

/** The exchange this sale replaced something in (replacement side). */
export async function getExchangeOrigin(saleId: string): Promise<{ return_id: string; return_number: string; original_sale_id: string; original_sale_number: string } | null> {
  const { supabase, businessId } = await loadPosContext();
  const { data } = await supabase
    .from("returns")
    .select("id, return_number, original_sale_id")
    .eq("business_id", businessId)
    .eq("replacement_sale_id", saleId)
    .maybeSingle();
  if (!data) return null;
  const { data: orig } = await supabase.from("sales").select("sale_number").eq("business_id", businessId).eq("id", data.original_sale_id as string).maybeSingle();
  return { return_id: data.id as string, return_number: data.return_number as string, original_sale_id: data.original_sale_id as string, original_sale_number: (orig?.sale_number as string) ?? "—" };
}
