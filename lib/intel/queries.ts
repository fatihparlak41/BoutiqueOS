import "server-only";

import { cache } from "react";
import { loadAppContext } from "@/lib/app-context";
import { listBranchOptions } from "@/lib/stock/queries";
import { intelCaps, INTEL_DEFAULTS, type IntelDimensions, type IntelHome, type IntelProduct } from "@/lib/intel/model";

/**
 * Read side of fashion intelligence: one RPC per surface (migration 20260917150000). The
 * RPC authorises from the caller's membership and decides which sections exist for the
 * role; the page renders the payload and never derives a signal itself.
 */

export const loadIntelContext = cache(async () => {
  const ctx = await loadAppContext();
  return { ...ctx, caps: intelCaps(ctx.role) };
});

export function parseDays(v: string | undefined): number {
  const n = Number.parseInt(v ?? "", 10);
  return [14, 30, 90].includes(n) ? n : INTEL_DEFAULTS.days;
}

function intParam(v: string | undefined, fallback: number, min: number, max: number): number {
  const n = Number.parseInt(v ?? "", 10);
  return Number.isFinite(n) ? Math.min(Math.max(n, min), max) : fallback;
}

/** Threshold overrides from the URL (manager tunes them; every value is bounded). */
export function parseThresholds(p: Record<string, string | undefined>) {
  return {
    p_min_sample: intParam(p.orneklem, INTEL_DEFAULTS.min_sample, 1, 1000),
    p_min_stock: intParam(p.min_stok, INTEL_DEFAULTS.min_stock, 0, 999),
    p_slow_age_days: intParam(p.yavas_yas, INTEL_DEFAULTS.slow_age_days, 1, 3650),
    p_slow_no_sale_days: intParam(p.yavas_satis, INTEL_DEFAULTS.slow_no_sale_days, 1, 3650),
    p_slow_min_qty: intParam(p.yavas_adet, INTEL_DEFAULTS.slow_min_qty, 1, 9999),
    p_replenish_min_sold: intParam(p.siparis_adet, INTEL_DEFAULTS.replenish_min_sold, 1, 9999),
    p_excess_min_qty: intParam(p.fazla_adet, INTEL_DEFAULTS.excess_min_qty, 1, 99999),
    p_excess_cover_days: intParam(p.fazla_gun, INTEL_DEFAULTS.excess_cover_days, 1, 3650),
  };
}

export async function resolveBranch(branchParam: string | undefined) {
  const branches = await listBranchOptions();
  const branchId = branchParam && branches.some((b) => b.id === branchParam) ? branchParam : null;
  return { branchId, branches: branches.map((b) => ({ id: b.id, name: b.name })) };
}

async function callIntel<T>(fn: string, args: Record<string, unknown>, label: string): Promise<T> {
  const { supabase } = await loadIntelContext();
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(`${label} okunamadı: ${error.message}`);
  return data as T;
}

export async function getIntelHome(branchId: string | null, days: number, thresholds: ReturnType<typeof parseThresholds>): Promise<IntelHome> {
  const { businessId } = await loadIntelContext();
  return callIntel<IntelHome>("rpc_intel_home", { p_business_id: businessId, p_branch_id: branchId, p_days: days, ...thresholds }, "Analiz");
}

export async function getIntelDimensions(branchId: string | null, days: number, categoryId: string | null, productId: string | null): Promise<IntelDimensions> {
  const { businessId } = await loadIntelContext();
  return callIntel<IntelDimensions>(
    "rpc_intel_dimensions",
    { p_business_id: businessId, p_branch_id: branchId, p_days: days, p_category_id: categoryId, p_product_id: productId, p_min_sample: INTEL_DEFAULTS.min_sample },
    "Beden / renk analizi",
  );
}

export async function getIntelProduct(productId: string, days = INTEL_DEFAULTS.days): Promise<IntelProduct> {
  return callIntel<IntelProduct>("rpc_intel_product", { p_product_id: productId, p_days: days, p_min_sample: INTEL_DEFAULTS.min_sample }, "Ürün analizi");
}
