import "server-only";

import { cache } from "react";
import { loadAppContext } from "@/lib/app-context";
import { listBranchOptions } from "@/lib/stock/queries";
import {
  reportCaps,
  type CustomersReport,
  type OverviewReport,
  type PaymentsReport,
  type ProductGroup,
  type ProductsReport,
  type ReceivingReport,
  type ReturnsReport,
  type SalesReport,
  type StaffReport,
  type StockReport,
  type Period,
} from "@/lib/reports/model";
import { periodQuery, resolvePeriod } from "@/lib/reports/period";

/**
 * Read side of reporting. One RPC call per report surface; every aggregate happens in
 * PostgreSQL (migration 20260917100000). The RPC authorises from the caller's membership
 * — the business id passed here is the tenant the shell resolved server-side and is
 * re-checked inside the function, never trusted on its own.
 *
 * Financial keys are absent from the payload for sales_staff; the page components render
 * whatever keys exist and do not derive money figures from unit counts.
 */

export const loadReportContext = cache(async () => {
  const ctx = await loadAppContext();
  return { ...ctx, caps: reportCaps(ctx.role), timezone: ctx.tenant.active.timezone };
});

/** Period from the URL, in the tenant timezone. */
export async function periodFromParams(params: { d?: string; from?: string; to?: string }): Promise<Period> {
  const { timezone } = await loadReportContext();
  return resolvePeriod(params, timezone);
}

/** Everything a report page needs before its one RPC: who is asking, the window, the branch filter, the shared query string. */
export async function reportPageState(params: { d?: string; from?: string; to?: string; sube?: string }) {
  const ctx = await loadReportContext();
  const [{ branchId, branches }] = await Promise.all([resolveBranchFilter(params.sube)]);
  const period = resolvePeriod(params, ctx.timezone);
  return { ...ctx, period, branchId, branches, query: periodQuery(period, { sube: branchId ?? undefined }) };
}

/** Branch filter: only a branch of this business is ever passed on. */
export async function resolveBranchFilter(branchParam: string | undefined): Promise<{ branchId: string | null; branches: Array<{ id: string; name: string }> }> {
  const branches = await listBranchOptions();
  const branchId = branchParam && branches.some((b) => b.id === branchParam) ? branchParam : null;
  return { branchId, branches: branches.map((b) => ({ id: b.id, name: b.name })) };
}

async function callReport<T>(fn: string, args: Record<string, unknown>, label: string): Promise<T> {
  const { supabase } = await loadReportContext();
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(`${label} raporu okunamadı: ${error.message}`);
  return data as T;
}

export async function getOverview(period: Period, branchId: string | null): Promise<OverviewReport> {
  const { businessId } = await loadReportContext();
  return callReport<OverviewReport>(
    "rpc_report_overview",
    { p_business_id: businessId, p_date_from: period.from, p_date_to: period.to, p_branch_id: branchId, p_prev_from: period.prevFrom, p_prev_to: period.prevTo },
    "Genel bakış",
  );
}

export async function getSalesReport(
  period: Period,
  filters: { branchId: string | null; salespersonId: string | null; categoryId: string | null; productId: string | null },
): Promise<SalesReport> {
  const { businessId } = await loadReportContext();
  return callReport<SalesReport>(
    "rpc_report_sales",
    {
      p_business_id: businessId, p_date_from: period.from, p_date_to: period.to, p_branch_id: filters.branchId,
      p_salesperson_id: filters.salespersonId, p_category_id: filters.categoryId, p_product_id: filters.productId,
    },
    "Satış",
  );
}

export async function getProductsReport(period: Period, branchId: string | null, group: ProductGroup, categoryId: string | null): Promise<ProductsReport> {
  const { businessId } = await loadReportContext();
  return callReport<ProductsReport>(
    "rpc_report_products",
    { p_business_id: businessId, p_date_from: period.from, p_date_to: period.to, p_branch_id: branchId, p_group: group, p_category_id: categoryId, p_limit: 50 },
    "Ürün performansı",
  );
}

export async function getStaffReport(period: Period, branchId: string | null): Promise<StaffReport> {
  const { businessId } = await loadReportContext();
  return callReport<StaffReport>("rpc_report_staff", { p_business_id: businessId, p_date_from: period.from, p_date_to: period.to, p_branch_id: branchId }, "Personel");
}

export async function getPaymentsReport(period: Period, branchId: string | null): Promise<PaymentsReport> {
  const { businessId } = await loadReportContext();
  return callReport<PaymentsReport>("rpc_report_payments", { p_business_id: businessId, p_date_from: period.from, p_date_to: period.to, p_branch_id: branchId }, "Ödeme");
}

export async function getStockReport(branchId: string | null, lowThreshold = 2): Promise<StockReport> {
  const { businessId } = await loadReportContext();
  return callReport<StockReport>("rpc_report_stock", { p_business_id: businessId, p_branch_id: branchId, p_low_threshold: lowThreshold }, "Stok");
}

export async function getReceivingReport(period: Period, branchId: string | null): Promise<ReceivingReport> {
  const { businessId } = await loadReportContext();
  return callReport<ReceivingReport>("rpc_report_receiving", { p_business_id: businessId, p_date_from: period.from, p_date_to: period.to, p_branch_id: branchId }, "Mal kabul");
}

export async function getCustomersReport(period: Period, branchId: string | null): Promise<CustomersReport> {
  const { businessId } = await loadReportContext();
  return callReport<CustomersReport>("rpc_report_customers", { p_business_id: businessId, p_date_from: period.from, p_date_to: period.to, p_branch_id: branchId }, "Müşteri");
}

export async function getReturnsReport(period: Period, branchId: string | null): Promise<ReturnsReport> {
  const { businessId } = await loadReportContext();
  return callReport<ReturnsReport>("rpc_report_returns", { p_business_id: businessId, p_date_from: period.from, p_date_to: period.to, p_branch_id: branchId }, "İade");
}
