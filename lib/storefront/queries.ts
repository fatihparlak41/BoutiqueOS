import "server-only";

import { createClient } from "@/lib/supabase/server";
import { requireTenant } from "@/lib/tenant";
import type { AdminProduct, StorefrontAdmin } from "@/lib/storefront/model";

/** Online-store admin reads. Each RPC proves owner/manager rank in the database. */
export async function getStorefrontAdmin(q: string | null, offset: number, limit: number): Promise<StorefrontAdmin> {
  const { active } = await requireTenant();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rpc_storefront_admin", { p_business_id: active.business_id, p_q: q, p_limit: limit, p_offset: offset });
  if (error) throw new Error(`Online mağaza okunamadı: ${error.message}`);
  return data as StorefrontAdmin;
}

export async function getStorefrontAdminProduct(productId: string): Promise<AdminProduct | null> {
  const { active } = await requireTenant();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rpc_storefront_admin_product", { p_business_id: active.business_id, p_product_id: productId });
  if (error) {
    if (/INVALID_PRODUCT/.test(error.message)) return null;
    throw new Error(`Ürün okunamadı: ${error.message}`);
  }
  return data as AdminProduct;
}
