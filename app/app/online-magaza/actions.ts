"use server";

import { revalidatePath, revalidateTag } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { requireTenant } from "@/lib/tenant";
import { reportDbError } from "@/lib/db-errors";
import { IMAGE_BUCKET } from "@/lib/catalog/images";
import { shopTag } from "@/lib/shop/queries";
import { PUBLIC_IMAGE_ROLES, storefrontCaps, type StorefrontActionState } from "@/lib/storefront/model";

/**
 * Online-store writes. Every mutation is one RPC that re-proves owner/manager rank in
 * the database; the only thing the app does itself is copy a published image into the
 * public bucket (with the caller's own session — storage policies decide, not the app).
 * After any change the storefront cache tag is dropped so the public pages re-read.
 */

const UUID = /^[0-9a-f-]{36}$/i;
const PUBLIC_BUCKET = "storefront-images";

async function manager() {
  const { active } = await requireTenant();
  if (!storefrontCaps(active.role).canManage) return null;
  return active;
}

async function currentSlug(businessId: string): Promise<string | null> {
  const supabase = await createClient();
  const { data } = await supabase.from("storefronts").select("slug").eq("business_id", businessId).maybeSingle();
  return (data as { slug: string } | null)?.slug ?? null;
}

function refresh(slug: string | null) {
  revalidatePath("/app/online-magaza", "layout");
  if (slug) revalidateTag(shopTag(slug));
}

export async function saveStorefrontAction(_prev: StorefrontActionState, formData: FormData): Promise<StorefrontActionState> {
  const active = await manager();
  if (!active) return { error: "Online mağazayı yalnız sahip ve yöneticiler yönetir.", ok: false };
  const before = await currentSlug(active.business_id);
  const settings = {
    enabled: formData.get("enabled") === "on",
    slug: String(formData.get("slug") ?? "").trim().toLowerCase(),
    store_name: String(formData.get("store_name") ?? "").trim(),
    tagline: String(formData.get("tagline") ?? "").trim(),
    announcement: String(formData.get("announcement") ?? "").trim(),
    about: String(formData.get("about") ?? "").trim(),
    instagram: String(formData.get("instagram") ?? "").trim(),
    whatsapp: String(formData.get("whatsapp") ?? "").trim(),
    contact_email: String(formData.get("contact_email") ?? "").trim(),
    contact_phone: String(formData.get("contact_phone") ?? "").trim(),
    fulfillment_branch_id: String(formData.get("fulfillment_branch_id") ?? "").trim(),
    stock_display: String(formData.get("stock_display") ?? "state"),
    low_stock_threshold: Number.parseInt(String(formData.get("low_stock_threshold") ?? "3"), 10),
    orders_enabled: formData.get("orders_enabled") === "on",
    order_hold_minutes: Number.parseInt(String(formData.get("order_hold_minutes") ?? "1440"), 10),
    pickup_note: String(formData.get("pickup_note") ?? "").trim(),
  };
  if (!/^[a-z0-9](?:[a-z0-9-]{1,48}[a-z0-9])$/.test(settings.slug)) return { error: "Mağaza adresi 3–50 karakter olmalı; yalnız küçük harf, rakam ve tire.", ok: false };
  if (settings.store_name.length < 2) return { error: "Mağaza adı gerekli.", ok: false };
  if (settings.fulfillment_branch_id && !UUID.test(settings.fulfillment_branch_id)) return { error: "Şube tanınmadı.", ok: false };
  if (!["state", "exact"].includes(settings.stock_display)) return { error: "Stok gösterimi tanınmadı.", ok: false };
  if (!Number.isFinite(settings.order_hold_minutes) || settings.order_hold_minutes < 30 || settings.order_hold_minutes > 10080) return { error: "Ayırma süresi 30 dakika ile 7 gün arasında olmalı.", ok: false };
  const supabase = await createClient();
  const { error } = await supabase.rpc("rpc_storefront_upsert", { p_business_id: active.business_id, p_settings: settings });
  if (error) return { error: reportDbError("storefront upsert", error), ok: false };
  refresh(before);
  refresh(settings.slug);
  return { error: null, ok: true };
}

export async function publishProductAction(_prev: StorefrontActionState, formData: FormData): Promise<StorefrontActionState> {
  const active = await manager();
  if (!active) return { error: "Yayınlamayı yalnız sahip ve yöneticiler yapar.", ok: false };
  const id = String(formData.get("product_id") ?? "");
  const published = formData.get("published") === "true";
  if (!UUID.test(id)) return { error: "Ürün bulunamadı.", ok: false };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rpc_storefront_publish_product", { p_business_id: active.business_id, p_product_id: id, p_published: published });
  if (error) return { error: reportDbError("publish product", error), ok: false };
  const r = data as { public_images?: number };
  refresh(await currentSlug(active.business_id));
  return { error: null, ok: true, message: published && (r.public_images ?? 0) === 0 ? "Yayınlandı — görseli yok; ürün sayfasından bir görsel yayınlayın." : undefined };
}

export async function setProductWebAction(_prev: StorefrontActionState, formData: FormData): Promise<StorefrontActionState> {
  const active = await manager();
  if (!active) return { error: "Bu ayarı yalnız sahip ve yöneticiler değiştirir.", ok: false };
  const id = String(formData.get("product_id") ?? "");
  if (!UUID.test(id)) return { error: "Ürün bulunamadı.", ok: false };
  const web = {
    web_title: String(formData.get("web_title") ?? "").trim(),
    web_description: String(formData.get("web_description") ?? "").trim(),
    web_slug: String(formData.get("web_slug") ?? "").trim().toLowerCase(),
    web_featured: formData.get("web_featured") === "on",
    web_sort_order: Number.parseInt(String(formData.get("web_sort_order") ?? "100"), 10),
  };
  if (web.web_slug && !/^[a-z0-9](?:[a-z0-9-]{0,78}[a-z0-9])?$/.test(web.web_slug)) return { error: "Ürün adresi yalnız küçük harf, rakam ve tire içerebilir.", ok: false };
  const supabase = await createClient();
  const { error } = await supabase.rpc("rpc_storefront_set_product_web", { p_business_id: active.business_id, p_product_id: id, p_web: web });
  if (error) return { error: reportDbError("set product web", error), ok: false };
  refresh(await currentSlug(active.business_id));
  return { error: null, ok: true };
}

export async function toggleFeaturedAction(_prev: StorefrontActionState, formData: FormData): Promise<StorefrontActionState> {
  const active = await manager();
  if (!active) return { error: "Bu ayarı yalnız sahip ve yöneticiler değiştirir.", ok: false };
  const id = String(formData.get("product_id") ?? "");
  const featured = formData.get("featured") === "true";
  if (!UUID.test(id)) return { error: "Ürün bulunamadı.", ok: false };
  const supabase = await createClient();
  const { error } = await supabase.rpc("rpc_storefront_set_product_web", { p_business_id: active.business_id, p_product_id: id, p_web: { web_featured: featured } });
  if (error) return { error: reportDbError("toggle featured", error), ok: false };
  refresh(await currentSlug(active.business_id));
  return { error: null, ok: true };
}

export async function setVariantWebAction(_prev: StorefrontActionState, formData: FormData): Promise<StorefrontActionState> {
  const active = await manager();
  if (!active) return { error: "Bu ayarı yalnız sahip ve yöneticiler değiştirir.", ok: false };
  const id = String(formData.get("variant_id") ?? "");
  const enabled = formData.get("enabled") === "true";
  if (!UUID.test(id)) return { error: "Varyant bulunamadı.", ok: false };
  const supabase = await createClient();
  const { error } = await supabase.rpc("rpc_storefront_set_variant_web", { p_business_id: active.business_id, p_variant_id: id, p_enabled: enabled });
  if (error) return { error: reportDbError("set variant web", error), ok: false };
  refresh(await currentSlug(active.business_id));
  return { error: null, ok: true };
}

/**
 * Publishes an image: copies the private object into the public bucket under
 * store/<business>/products/<product>/<image>.<ext> and records the path. Only the
 * public roles are copied — the RPC refuses the rest even if the copy were attempted.
 */
export async function publishImageAction(_prev: StorefrontActionState, formData: FormData): Promise<StorefrontActionState> {
  const active = await manager();
  if (!active) return { error: "Görsel yayınlamayı yalnız sahip ve yöneticiler yapar.", ok: false };
  const imageId = String(formData.get("image_id") ?? "");
  const unpublish = formData.get("unpublish") === "true";
  if (!UUID.test(imageId)) return { error: "Görsel bulunamadı.", ok: false };
  const supabase = await createClient();
  const { data: img, error: readErr } = await supabase
    .from("product_images")
    .select("id, product_id, role, storage_path, public_path, mime_type")
    .eq("id", imageId)
    .eq("business_id", active.business_id)
    .maybeSingle();
  if (readErr || !img) return { error: "Görsel bulunamadı.", ok: false };
  const row = img as { id: string; product_id: string; role: string; storage_path: string | null; public_path: string | null; mime_type: string | null };

  if (unpublish) {
    const { error } = await supabase.rpc("rpc_storefront_set_image_public", { p_business_id: active.business_id, p_image_id: row.id, p_public_path: null });
    if (error) return { error: reportDbError("unpublish image", error), ok: false };
    if (row.public_path) await supabase.storage.from(PUBLIC_BUCKET).remove([row.public_path]);
    refresh(await currentSlug(active.business_id));
    return { error: null, ok: true };
  }

  if (!(PUBLIC_IMAGE_ROLES as readonly string[]).includes(row.role)) return { error: "Etiket ve mal kabul görselleri hiçbir zaman yayınlanmaz.", ok: false };
  if (!row.storage_path) return { error: "Bu görselin dosyası yok.", ok: false };
  const ext = row.mime_type === "image/png" ? "png" : row.mime_type === "image/webp" ? "webp" : "jpg";
  const publicPath = `store/${active.business_id}/products/${row.product_id}/${row.id}.${ext}`;
  if (row.public_path !== publicPath) {
    const { error: copyErr } = await supabase.storage.from(IMAGE_BUCKET).copy(row.storage_path, publicPath, { destinationBucket: PUBLIC_BUCKET });
    if (copyErr && !/already exists|Duplicate/i.test(copyErr.message)) {
      console.error("[storefront] image copy failed:", copyErr.message);
      return { error: "Görsel kopyalanamadı. Tekrar deneyin.", ok: false };
    }
  }
  const { error } = await supabase.rpc("rpc_storefront_set_image_public", { p_business_id: active.business_id, p_image_id: row.id, p_public_path: publicPath });
  if (error) return { error: reportDbError("publish image", error), ok: false };
  refresh(await currentSlug(active.business_id));
  return { error: null, ok: true };
}
