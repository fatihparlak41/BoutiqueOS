import "server-only";

import { loadAppContext } from "@/lib/app-context";
import { describeVariants } from "@/lib/stock/count-queries";
import {
  posCaps,
  type PaymentMethod,
  type PosCustomer,
  type PosItem,
  type PosMember,
  type Register,
  type RegisterSession,
  type SaleReceipt,
} from "@/lib/pos/model";

/**
 * Read side of the POS. Every query is RLS-scoped and additionally filtered by the
 * tenant resolved on the server. Nothing here touches variant_cost_pools,
 * inventory_movement_costs, sale_item_costs or sale_costs: the terminal shows selling
 * prices and availability, never cost.
 */

export const POS_SEARCH_LIMIT = 40;

function num(value: unknown): number {
  const n = typeof value === "number" ? value : Number(value);
  return Number.isFinite(n) ? n : 0;
}
function sanitize(term: string): string {
  return term.replace(/[%_,()]/g, " ").trim().slice(0, 60);
}

/** Tenant + role + the caller's own discount authority (business_members: own row is readable). */
export async function loadPosContext() {
  const ctx = await loadAppContext();
  const { data } = await ctx.supabase
    .from("business_members")
    .select("max_discount_pct")
    .eq("business_id", ctx.businessId)
    .eq("user_id", ctx.tenant.user.id)
    .maybeSingle();
  const maxDiscount = num(data?.max_discount_pct);
  return { ...ctx, caps: posCaps(ctx.role, maxDiscount) };
}

// ------------------------------------------------------------------ registers + sessions

export async function listRegisters(): Promise<Register[]> {
  const { supabase, businessId, branchId } = await loadPosContext();
  if (!branchId) return [];
  const [{ data: regs, error }, { data: sessions, error: sessError }] = await Promise.all([
    supabase
      .from("cash_registers")
      .select("id, branch_id, name, is_active, device_ref")
      .eq("business_id", businessId)
      .eq("branch_id", branchId)
      .order("name"),
    supabase
      .from("register_sessions")
      .select("id, cash_register_id, session_number, status, opened_by, opened_at")
      .eq("business_id", businessId)
      .eq("branch_id", branchId)
      .eq("status", "open"),
  ]);
  if (error) throw new Error(`Kasalar okunamadı: ${error.message}`);
  if (sessError) throw new Error(`Kasa oturumları okunamadı: ${sessError.message}`);
  const members = await listMembers();
  const nameOf = (id: string) => members.find((m) => m.user_id === id)?.full_name ?? null;
  return (regs ?? []).map((r) => {
    const s = (sessions ?? []).find((x) => x.cash_register_id === r.id);
    const open: RegisterSession | null = s
      ? {
          id: s.id as string,
          cash_register_id: s.cash_register_id as string,
          session_number: s.session_number as string,
          status: "open",
          opened_by: s.opened_by as string,
          opened_by_name: nameOf(s.opened_by as string),
          opened_at: s.opened_at as string,
        }
      : null;
    return {
      id: r.id as string,
      branch_id: r.branch_id as string,
      name: r.name as string,
      is_active: Boolean(r.is_active),
      device_ref: (r.device_ref as string | null) ?? null,
      open_session: open,
    };
  });
}

/** Name-only member directory (rpc_pos_members): salesperson picker and receipt names. */
export async function listMembers(): Promise<PosMember[]> {
  const { supabase, businessId } = await loadPosContext();
  const { data, error } = await supabase.rpc("rpc_pos_members", { p_business_id: businessId });
  if (error) throw new Error(`Ekip okunamadı: ${error.message}`);
  return ((data ?? []) as Array<Record<string, unknown>>).map((m) => ({
    user_id: m.user_id as string,
    full_name: (m.full_name as string | null) ?? null,
    can_sell: Boolean(m.can_sell),
    is_self: Boolean(m.is_self),
  }));
}

// ------------------------------------------------------------------ items

/** Adds list price and branch availability to described variants. */
async function toPosItems(variantIds: string[]): Promise<PosItem[]> {
  const ids = [...new Set(variantIds)];
  if (ids.length === 0) return [];
  const { supabase, businessId, branchId } = await loadPosContext();
  const [meta, { data: variants, error }, { data: stock }] = await Promise.all([
    describeVariants(ids),
    supabase
      .from("product_variants")
      .select("id, product_id, status, sale_price_override")
      .eq("business_id", businessId)
      .in("id", ids),
    branchId
      ? supabase
          .from("v_stock_available")
          .select("variant_id, available_quantity")
          .eq("business_id", businessId)
          .eq("branch_id", branchId)
          .in("variant_id", ids)
      : Promise.resolve({ data: [] as Array<Record<string, unknown>> }),
  ]);
  if (error) throw new Error(`Fiyatlar okunamadı: ${error.message}`);
  const productIds = [...new Set((variants ?? []).map((v) => v.product_id as string))];
  const { data: products, error: productError } = await supabase
    .from("products")
    .select("id, default_sale_price, status")
    .eq("business_id", businessId)
    .in("id", productIds);
  if (productError) throw new Error(`Ürünler okunamadı: ${productError.message}`);
  const out: PosItem[] = [];
  for (const v of variants ?? []) {
    const product = (products ?? []).find((p) => p.id === v.product_id);
    if (v.status !== "active" || product?.status !== "active") continue; // not sellable: never offered
    const info = meta.get(v.id as string);
    if (!info) continue;
    const price = v.sale_price_override !== null && v.sale_price_override !== undefined ? num(v.sale_price_override) : num(product?.default_sale_price);
    const avail = (stock ?? []).find((s) => s.variant_id === v.id);
    out.push({ ...info, price, available: num(avail?.available_quantity) });
  }
  return out.sort((a, b) => a.product_name.localeCompare(b.product_name, "tr") || a.sku.localeCompare(b.sku, "tr"));
}

/** Exact barcode match inside the tenant (RLS + business filter); leading zeros are part of the code. */
export async function lookupBarcode(code: string): Promise<PosItem | null> {
  const barcode = code.trim();
  if (!barcode) return null;
  const { supabase, businessId } = await loadPosContext();
  const { data, error } = await supabase
    .from("barcodes")
    .select("variant_id")
    .eq("business_id", businessId)
    .eq("barcode", barcode)
    .limit(1)
    .maybeSingle();
  if (error) throw new Error(`Barkod okunamadı: ${error.message}`);
  if (!data) return null;
  const items = await toPosItems([data.variant_id as string]);
  return items[0] ?? null;
}

/** Product name / SKU / barcode search for the picker. */
export async function searchItems(term: string): Promise<PosItem[]> {
  const search = sanitize(term);
  if (search.length < 2) return [];
  const { supabase, businessId } = await loadPosContext();
  const [bc, sku, products] = await Promise.all([
    supabase.from("barcodes").select("variant_id").eq("business_id", businessId).ilike("barcode", `%${search}%`).limit(POS_SEARCH_LIMIT),
    supabase.from("product_variants").select("id").eq("business_id", businessId).eq("status", "active").ilike("sku", `%${search}%`).limit(POS_SEARCH_LIMIT),
    supabase.from("products").select("id").eq("business_id", businessId).eq("status", "active").ilike("name", `%${search}%`).limit(POS_SEARCH_LIMIT),
  ]);
  for (const r of [bc, sku, products]) if (r.error) throw new Error(`Arama başarısız: ${r.error.message}`);
  const ids = new Set<string>();
  for (const r of bc.data ?? []) ids.add(r.variant_id as string);
  for (const r of sku.data ?? []) ids.add(r.id as string);
  const productIds = (products.data ?? []).map((p) => p.id as string);
  if (productIds.length > 0) {
    const { data: siblings } = await supabase
      .from("product_variants")
      .select("id")
      .eq("business_id", businessId)
      .eq("status", "active")
      .in("product_id", productIds)
      .limit(POS_SEARCH_LIMIT);
    for (const r of siblings ?? []) ids.add(r.id as string);
  }
  return toPosItems([...ids].slice(0, POS_SEARCH_LIMIT));
}

// ------------------------------------------------------------------ customers

export async function searchCustomers(term: string): Promise<PosCustomer[]> {
  const search = sanitize(term);
  if (search.length < 2) return [];
  const { supabase, businessId } = await loadPosContext();
  const { data, error } = await supabase
    .from("customers")
    .select("id, full_name, phone")
    .eq("business_id", businessId)
    .eq("is_active", true)
    .or(`full_name.ilike.%${search}%,phone.ilike.%${search}%`)
    .order("full_name")
    .limit(20);
  if (error) throw new Error(`Müşteri araması başarısız: ${error.message}`);
  return (data ?? []).map((c) => ({ id: c.id as string, full_name: (c.full_name as string | null) ?? null, phone: c.phone as string }));
}

// ------------------------------------------------------------------ receipt

export async function getSaleReceipt(saleId: string): Promise<SaleReceipt | null> {
  const { supabase, businessId, tenant } = await loadPosContext();
  const { data: sale, error } = await supabase
    .from("sales")
    .select("id, sale_number, status, occurred_at, branch_id, sold_by, salesperson_id, customer_id, subtotal, discount_amount, total, change_given_base, note")
    .eq("business_id", businessId)
    .eq("id", saleId)
    .maybeSingle();
  if (error) throw new Error(`Satış okunamadı: ${error.message}`);
  if (!sale) return null;

  const [{ data: items, error: itemError }, { data: payments, error: payError }, members, customer] = await Promise.all([
    supabase
      .from("sale_items")
      .select("id, variant_id, quantity, list_price, unit_price_at_sale, discount_amount, line_total")
      .eq("business_id", businessId)
      .eq("sale_id", saleId),
    supabase.from("sale_payments").select("id, method, amount, currency").eq("business_id", businessId).eq("sale_id", saleId).order("created_at"),
    listMembers(),
    sale.customer_id
      ? supabase.from("customers").select("id, full_name, phone").eq("business_id", businessId).eq("id", sale.customer_id as string).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  if (itemError) throw new Error(`Satış satırları okunamadı: ${itemError.message}`);
  if (payError) throw new Error(`Ödemeler okunamadı: ${payError.message}`);
  const meta = await describeVariants((items ?? []).map((i) => i.variant_id as string));
  const nameOf = (id: string) => members.find((m) => m.user_id === id)?.full_name ?? null;
  const c = customer.data as { id: string; full_name: string | null; phone: string } | null;

  return {
    id: sale.id as string,
    sale_number: sale.sale_number as string,
    status: sale.status as "completed" | "voided",
    occurred_at: sale.occurred_at as string,
    branch_name: tenant.active.branches.find((b) => b.id === sale.branch_id)?.name ?? "—",
    cashier_name: nameOf(sale.sold_by as string),
    salesperson_name: nameOf(sale.salesperson_id as string),
    salesperson_is_cashier: sale.salesperson_id === sale.sold_by,
    customer: c ? { id: c.id, full_name: c.full_name ?? null, phone: c.phone } : null,
    subtotal: num(sale.subtotal),
    discount_amount: num(sale.discount_amount),
    total: num(sale.total),
    change_given: num(sale.change_given_base),
    note: (sale.note as string | null) ?? null,
    items: (items ?? [])
      .map((i) => ({
        id: i.id as string,
        variant: meta.get(i.variant_id as string) ?? {
          variant_id: i.variant_id as string, product_id: "", product_name: "—", sku: "—", options: "", color: null, size: null, primary_barcode: null, thumbnail_url: null,
        },
        quantity: num(i.quantity),
        list_price: num(i.list_price),
        unit_price: num(i.unit_price_at_sale),
        discount_amount: num(i.discount_amount),
        line_total: num(i.line_total),
      }))
      .sort((a, b) => a.variant.product_name.localeCompare(b.variant.product_name, "tr")),
    payments: (payments ?? []).map((p) => ({ id: p.id as string, method: p.method as PaymentMethod | "bank_transfer", amount: num(p.amount), currency: p.currency as string })),
  };
}
