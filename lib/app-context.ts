import "server-only";

import { createClient } from "@/lib/supabase/server";
import { requireTenant } from "@/lib/tenant";

/**
 * Tenant + client for every server module outside the catalogue.
 *
 * business_id and branch_id are resolved here, from requireTenant(), which re-proves the
 * membership against PostgreSQL on each request. They are never read from a form, and RLS
 * re-checks them on the row regardless.
 */
export async function loadAppContext() {
  const tenant = await requireTenant();
  const supabase = await createClient();
  return {
    supabase,
    tenant,
    businessId: tenant.active.business_id,
    /** The branch the shell is showing; null only when the business has no active branch. */
    branchId: tenant.branch?.id ?? null,
    role: tenant.active.role,
  };
}

export type AppContext = Awaited<ReturnType<typeof loadAppContext>>;
