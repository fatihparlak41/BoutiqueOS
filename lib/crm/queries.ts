import "server-only";

import { cache } from "react";
import { loadAppContext } from "@/lib/app-context";
import { describeVariants } from "@/lib/stock/count-queries";
import { listMembers } from "@/lib/pos/queries";
import {
  crmCaps,
  type Customer,
  type CustomerFinancials,
  type CustomerHit,
  type CustomerReservation,
  type CustomerSale,
  type CustomerSource,
  type DuplicateHit,
  type Reservation,
  type ReservationStatus,
} from "@/lib/crm/model";

/**
 * Read side of the CRM. Customer rows and reservations are RLS-scoped to the tenant and
 * to the selling roles; search and duplicate probes go through SECURITY DEFINER RPCs
 * that return a bounded list, never the table. Sales history is derived from `sales`
 * (own visibility scope applies to sales_staff), never copied into CRM tables.
 */

function num(v: unknown): number {
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

export async function loadCrmContext() {
  const ctx = await loadAppContext();
  return { ...ctx, caps: crmCaps(ctx.role) };
}

function toCustomer(r: Record<string, unknown>): Customer {
  return {
    id: String(r.id), full_name: String(r.full_name ?? "—"), phone: (r.phone as string | null) ?? null, email: (r.email as string | null) ?? null,
    instagram: (r.instagram as string | null) ?? null, source: (r.source as string | null) ?? null, notes: (r.notes as string | null) ?? null,
    is_active: Boolean(r.is_active), order_count: num(r.order_count), last_purchase_at: (r.last_purchase_at as string | null) ?? null, created_at: String(r.created_at ?? ""),
  };
}

export const listSources = cache(async (): Promise<CustomerSource[]> => {
  const { supabase, businessId } = await loadCrmContext();
  const { data, error } = await supabase.from("customer_sources").select("business_id, code, label, sort_order, is_active").or(`business_id.is.null,business_id.eq.${businessId}`).eq("is_active", true).order("sort_order");
  if (error) throw new Error(`Kaynaklar okunamadı: ${error.message}`);
  // a tenant row with the same code overrides the platform default
  const map = new Map<string, CustomerSource>();
  for (const s of data ?? []) if (s.business_id === null && !map.has(s.code as string)) map.set(s.code as string, { code: s.code as string, label: s.label as string });
  for (const s of data ?? []) if (s.business_id !== null) map.set(s.code as string, { code: s.code as string, label: s.label as string });
  return [...map.values()];
});

/** Recent customers for the list page (bounded); search goes through the RPC. */
export async function listRecentCustomers(limit = 30): Promise<Customer[]> {
  const { supabase, businessId } = await loadCrmContext();
  const { data, error } = await supabase
    .from("customers")
    .select("id, full_name, phone, email, instagram, source, notes, is_active, order_count, last_purchase_at, created_at")
    .eq("business_id", businessId)
    .order("created_at", { ascending: false })
    .limit(limit);
  if (error) throw new Error(`Müşteriler okunamadı: ${error.message}`);
  return (data ?? []).map((r) => toCustomer(r as Record<string, unknown>));
}

export async function searchCustomers(query: string, limit = 20): Promise<CustomerHit[]> {
  const { supabase, businessId } = await loadCrmContext();
  const { data, error } = await supabase.rpc("rpc_customer_search", { p_business_id: businessId, p_query: query.trim().slice(0, 80), p_limit: limit });
  if (error) throw new Error(`Arama yapılamadı: ${error.message}`);
  return ((Array.isArray(data) ? data : []) as Array<Record<string, unknown>>).map((r) => ({
    id: String(r.id), full_name: String(r.full_name ?? "—"), phone: (r.phone as string | null) ?? null, email: (r.email as string | null) ?? null,
    instagram: (r.instagram as string | null) ?? null, source: (r.source as string | null) ?? null, is_active: Boolean(r.is_active),
    order_count: num(r.order_count), last_purchase_at: (r.last_purchase_at as string | null) ?? null,
  }));
}

export async function probeDuplicates(input: { phone: string | null; email: string | null; instagram: string | null; excludeId?: string | null }): Promise<DuplicateHit[]> {
  const { supabase, businessId } = await loadCrmContext();
  if (!input.phone && !input.email && !input.instagram) return [];
  const { data, error } = await supabase.rpc("rpc_customer_duplicates", {
    p_business_id: businessId, p_phone: input.phone, p_email: input.email, p_instagram: input.instagram, p_exclude_id: input.excludeId ?? null,
  });
  if (error) throw new Error(`Benzer kayıt sorgusu yapılamadı: ${error.message}`);
  return ((Array.isArray(data) ? data : []) as Array<Record<string, unknown>>).map((r) => ({
    id: String(r.id), full_name: String(r.full_name ?? "—"), phone: (r.phone as string | null) ?? null, email: (r.email as string | null) ?? null,
    instagram: (r.instagram as string | null) ?? null, match: r.match as DuplicateHit["match"],
  }));
}

export async function getCustomer(id: string): Promise<Customer | null> {
  const { supabase, businessId } = await loadCrmContext();
  const { data, error } = await supabase
    .from("customers")
    .select("id, full_name, phone, email, instagram, source, notes, is_active, order_count, last_purchase_at, created_at")
    .eq("business_id", businessId)
    .eq("id", id)
    .maybeSingle();
  if (error) throw new Error(`Müşteri okunamadı: ${error.message}`);
  return data ? toCustomer(data as Record<string, unknown>) : null;
}

/** Sales history straight from `sales` (RLS: sales_staff sees the sales they may see). */
export async function listCustomerSales(customerId: string): Promise<CustomerSale[]> {
  const { supabase, businessId, tenant } = await loadCrmContext();
  const { data: sales, error } = await supabase
    .from("sales")
    .select("id, sale_number, status, occurred_at, branch_id, total")
    .eq("business_id", businessId)
    .eq("customer_id", customerId)
    .order("occurred_at", { ascending: false })
    .limit(100);
  if (error) throw new Error(`Satış geçmişi okunamadı: ${error.message}`);
  const ids = (sales ?? []).map((s) => s.id as string);
  if (ids.length === 0) return [];
  const [{ data: items }, { data: returns }] = await Promise.all([
    supabase.from("sale_items").select("sale_id, variant_id, quantity").eq("business_id", businessId).in("sale_id", ids),
    supabase.from("returns").select("id, return_number, return_type, original_sale_id").eq("business_id", businessId).in("original_sale_id", ids),
  ]);
  const meta = await describeVariants((items ?? []).map((i) => i.variant_id as string));
  return (sales ?? []).map((s) => {
    const its = (items ?? []).filter((i) => i.sale_id === s.id);
    return {
      id: s.id as string, sale_number: s.sale_number as string, status: s.status as "completed" | "voided", occurred_at: s.occurred_at as string,
      branch_name: tenant.active.branches.find((b) => b.id === s.branch_id)?.name ?? "—", total: num(s.total),
      item_count: its.reduce((a, i) => a + num(i.quantity), 0),
      items_summary: its.map((i) => { const m = meta.get(i.variant_id as string); return `${num(i.quantity)}× ${m?.product_name ?? "—"}${m?.options ? ` (${m.options})` : ""}`; }).join(", "),
      returns: (returns ?? []).filter((r) => r.original_sale_id === s.id).map((r) => ({ id: r.id as string, return_number: r.return_number as string, return_type: r.return_type as string })),
    };
  });
}

export async function listCustomerReservations(customerId: string): Promise<CustomerReservation[]> {
  const { supabase, businessId } = await loadCrmContext();
  const { data, error } = await supabase
    .from("reservations")
    .select("id, reservation_number, status, expires_at, created_at, reservation_items(quantity)")
    .eq("business_id", businessId)
    .eq("customer_id", customerId)
    .order("created_at", { ascending: false })
    .limit(50);
  if (error) throw new Error(`Rezervasyonlar okunamadı: ${error.message}`);
  return (data ?? []).map((r) => ({
    id: r.id as string, reservation_number: r.reservation_number as string, status: r.status as ReservationStatus, expires_at: r.expires_at as string,
    created_at: r.created_at as string, item_count: ((r.reservation_items as Array<{ quantity: number }> | null) ?? []).reduce((a, i) => a + num(i.quantity), 0),
  }));
}

/** manager+ only (RLS on sale_costs keeps it empty for anyone else; the page also gates it). */
export async function getCustomerFinancials(customerId: string): Promise<CustomerFinancials | null> {
  const { supabase, businessId, caps } = await loadCrmContext();
  if (!caps.canManage) return null;
  const { data: sales } = await supabase.from("sales").select("id, total").eq("business_id", businessId).eq("customer_id", customerId).eq("status", "completed");
  const ids = (sales ?? []).map((s) => s.id as string);
  if (ids.length === 0) return { revenue: 0, cogs: 0, gross_margin: 0, sales: 0 };
  const { data: costs } = await supabase.from("sale_costs").select("sale_id, total_cost_base").eq("business_id", businessId).in("sale_id", ids);
  const revenue = (sales ?? []).reduce((a, s) => a + num(s.total), 0);
  const cogs = (costs ?? []).reduce((a, c) => a + num(c.total_cost_base), 0);
  return { revenue, cogs, gross_margin: revenue - cogs, sales: ids.length };
}

// ------------------------------------------------------------------ reservations

const RESERVATION_SELECT = "id, reservation_number, status, branch_id, customer_id, source, expires_at, note, created_at, created_by, cancelled_at, cancel_reason, fulfilled_at, converted_to_sale_id, reservation_items(variant_id, quantity)";

async function toReservations(rows: Array<Record<string, unknown>>): Promise<Reservation[]> {
  const { supabase, businessId, branchId, tenant } = await loadCrmContext();
  if (rows.length === 0) return [];
  const variantIds = rows.flatMap((r) => ((r.reservation_items as Array<{ variant_id: string }> | null) ?? []).map((i) => i.variant_id));
  const customerIds = [...new Set(rows.map((r) => r.customer_id as string | null).filter((x): x is string => Boolean(x)))];
  const saleIds = [...new Set(rows.map((r) => r.converted_to_sale_id as string | null).filter((x): x is string => Boolean(x)))];
  const [meta, members, { data: customers }, { data: sales }, { data: variants }, { data: stock }] = await Promise.all([
    describeVariants(variantIds),
    listMembers(),
    customerIds.length ? supabase.from("customers").select("id, full_name, phone").eq("business_id", businessId).in("id", customerIds) : Promise.resolve({ data: [] as Array<Record<string, unknown>> }),
    saleIds.length ? supabase.from("sales").select("id, sale_number").eq("business_id", businessId).in("id", saleIds) : Promise.resolve({ data: [] as Array<Record<string, unknown>> }),
    variantIds.length ? supabase.from("product_variants").select("id, product_id, sale_price_override, products(default_sale_price)").eq("business_id", businessId).in("id", [...new Set(variantIds)]) : Promise.resolve({ data: [] as Array<Record<string, unknown>> }),
    variantIds.length && branchId ? supabase.from("v_stock_available").select("variant_id, branch_id, available_quantity").eq("business_id", businessId).in("variant_id", [...new Set(variantIds)]) : Promise.resolve({ data: [] as Array<Record<string, unknown>> }),
  ]);
  const now = Date.now();
  return rows.map((r) => {
    const c = (customers ?? []).find((x) => x.id === r.customer_id) as Record<string, unknown> | undefined;
    const items = ((r.reservation_items as Array<{ variant_id: string; quantity: number }> | null) ?? []).map((i) => {
      const v = (variants ?? []).find((x) => x.id === i.variant_id) as Record<string, unknown> | undefined;
      const product = v?.products as { default_sale_price: unknown } | null | undefined;
      const price = v?.sale_price_override !== null && v?.sale_price_override !== undefined ? num(v.sale_price_override) : num(product?.default_sale_price);
      const s = (stock ?? []).find((x) => x.variant_id === i.variant_id && x.branch_id === r.branch_id);
      return {
        variant: meta.get(i.variant_id) ?? { variant_id: i.variant_id, product_id: "", product_name: "—", sku: "—", options: "", color: null, size: null, primary_barcode: null, thumbnail_url: null },
        quantity: num(i.quantity), price, available: num(s?.available_quantity),
      };
    });
    return {
      id: String(r.id), reservation_number: String(r.reservation_number), status: r.status as ReservationStatus, branch_id: String(r.branch_id),
      branch_name: tenant.active.branches.find((b) => b.id === r.branch_id)?.name ?? "—",
      customer: c ? { id: String(c.id), full_name: String(c.full_name ?? "—"), phone: (c.phone as string | null) ?? null } : null,
      source: (r.source as string | null) ?? null, expires_at: String(r.expires_at), note: (r.note as string | null) ?? null, created_at: String(r.created_at),
      created_by_name: members.find((m) => m.user_id === r.created_by)?.full_name ?? null,
      cancelled_at: (r.cancelled_at as string | null) ?? null, cancel_reason: (r.cancel_reason as string | null) ?? null, fulfilled_at: (r.fulfilled_at as string | null) ?? null,
      converted_to_sale_id: (r.converted_to_sale_id as string | null) ?? null,
      converted_sale_number: ((sales ?? []).find((s) => s.id === r.converted_to_sale_id)?.sale_number as string | undefined) ?? null,
      items, is_past_due: r.status === "active" && new Date(String(r.expires_at)).getTime() <= now,
    };
  });
}

export async function listReservations(status: "active" | "history" = "active", limit = 50): Promise<Reservation[]> {
  const { supabase, businessId } = await loadCrmContext();
  let q = supabase.from("reservations").select(RESERVATION_SELECT).eq("business_id", businessId);
  q = status === "active" ? q.eq("status", "active").order("expires_at", { ascending: true }) : q.neq("status", "active").order("created_at", { ascending: false });
  const { data, error } = await q.limit(limit);
  if (error) throw new Error(`Rezervasyonlar okunamadı: ${error.message}`);
  return toReservations((data ?? []) as Array<Record<string, unknown>>);
}

export async function getReservation(id: string): Promise<Reservation | null> {
  const { supabase, businessId } = await loadCrmContext();
  const { data, error } = await supabase.from("reservations").select(RESERVATION_SELECT).eq("business_id", businessId).eq("id", id).maybeSingle();
  if (error) throw new Error(`Rezervasyon okunamadı: ${error.message}`);
  if (!data) return null;
  return (await toReservations([data as Record<string, unknown>]))[0] ?? null;
}

/** Active holds of the terminal's branch (for the POS pick list). */
export async function listActiveReservationsForBranch(limit = 20): Promise<Reservation[]> {
  const { supabase, businessId, branchId } = await loadAppContext();
  if (!branchId) return [];
  const { data, error } = await supabase.from("reservations").select(RESERVATION_SELECT).eq("business_id", businessId).eq("branch_id", branchId).eq("status", "active").gt("expires_at", new Date().toISOString()).order("expires_at").limit(limit);
  if (error) throw new Error(`Rezervasyonlar okunamadı: ${error.message}`);
  return toReservations((data ?? []) as Array<Record<string, unknown>>);
}
