import "server-only";

import { cache } from "react";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import {
  PAGE_SIZE,
  type InvoiceFilter,
  type PlatformApplicationDetail,
  type PlatformApplicationList,
  type PlatformBillingOverview,
  type PlatformBusinessDetail,
  type PlatformBusinessList,
  type PlatformInvoiceDetail,
  type PlatformInvoiceList,
  type PlatformPlan,
  type PlatformSubscriptionList,
  type SubscriptionFilter,
} from "@/lib/platform/model";

/**
 * Platform console reads. Every RPC below proves the platform role itself
 * (fn_require_platform_admin); the layout additionally asks rpc_platform_whoami so a
 * tenant user who guesses the URL gets a 404 — the console does not exist for them.
 * Platform authority is never an OR-branch in tenant RLS: these are separate,
 * SECURITY DEFINER surfaces that read across tenants by design.
 */

export const requirePlatformAdmin = cache(async () => {
  const supabase = await createClient();
  const { data: claimsData } = await supabase.auth.getClaims();
  if (!claimsData?.claims?.sub) redirect("/login");
  const { data, error } = await supabase.rpc("rpc_platform_whoami");
  if (error) throw new Error(`Platform durumu okunamadı: ${error.message}`);
  const who = data as { platform_admin: boolean; pending_applications: number | null };
  if (!who.platform_admin) notFound();
  return {
    supabase,
    userId: String(claimsData.claims.sub),
    email: typeof claimsData.claims.email === "string" ? claimsData.claims.email : null,
    pendingApplications: who.pending_applications ?? 0,
  };
});

export async function listApplications(status: string | null, offset: number): Promise<PlatformApplicationList> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("rpc_platform_applications", { p_status: status, p_limit: PAGE_SIZE, p_offset: offset });
  if (error) throw new Error(`Başvurular okunamadı: ${error.message}`);
  return data as PlatformApplicationList;
}

export async function getApplication(id: string): Promise<PlatformApplicationDetail | null> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("rpc_platform_application_detail", { p_application_id: id });
  if (error) {
    if (/NOT_FOUND/.test(error.message)) return null;
    throw new Error(`Başvuru okunamadı: ${error.message}`);
  }
  return data as PlatformApplicationDetail;
}

export async function listBusinesses(status: string | null, q: string | null, offset: number): Promise<PlatformBusinessList> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("rpc_platform_businesses", { p_status: status, p_q: q, p_limit: PAGE_SIZE, p_offset: offset });
  if (error) throw new Error(`İşletmeler okunamadı: ${error.message}`);
  return data as PlatformBusinessList;
}

export async function getBusiness(id: string): Promise<PlatformBusinessDetail | null> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("rpc_platform_business_detail", { p_business_id: id });
  if (error) {
    if (/NOT_FOUND/.test(error.message)) return null;
    throw new Error(`İşletme okunamadı: ${error.message}`);
  }
  return data as PlatformBusinessDetail;
}

export async function listPlans(): Promise<PlatformPlan[]> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("rpc_platform_plans");
  if (error) throw new Error(`Planlar okunamadı: ${error.message}`);
  return (data ?? []) as PlatformPlan[];
}

// ---------------------------------------------------------------- billing (Phase 13B)

export async function getBillingOverview(): Promise<PlatformBillingOverview> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("rpc_platform_billing_overview");
  if (error) throw new Error(`Faturalama özeti okunamadı: ${error.message}`);
  return data as PlatformBillingOverview;
}

export async function listInvoices(status: InvoiceFilter | null, q: string | null, offset: number): Promise<PlatformInvoiceList> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("rpc_platform_invoices", { p_status: status, p_q: q, p_limit: PAGE_SIZE, p_offset: offset });
  if (error) throw new Error(`Faturalar okunamadı: ${error.message}`);
  return data as PlatformInvoiceList;
}

export async function getInvoice(id: string): Promise<PlatformInvoiceDetail | null> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("rpc_platform_invoice_detail", { p_invoice_id: id });
  if (error) {
    if (/NOT_FOUND/.test(error.message)) return null;
    throw new Error(`Fatura okunamadı: ${error.message}`);
  }
  return data as PlatformInvoiceDetail;
}

export async function listSubscriptions(status: SubscriptionFilter | null, q: string | null, offset: number): Promise<PlatformSubscriptionList> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("rpc_platform_subscriptions", { p_status: status, p_q: q, p_limit: PAGE_SIZE, p_offset: offset });
  if (error) throw new Error(`Abonelikler okunamadı: ${error.message}`);
  return data as PlatformSubscriptionList;
}
