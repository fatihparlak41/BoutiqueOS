"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { loadCatalogContext, type ProductStatus, type VariantStatus } from "@/lib/catalog/queries";
import { parseMoney } from "@/lib/catalog/format";
import { reportDbError } from "@/lib/catalog/errors";
import type { ActionState } from "@/lib/catalog/action-state";
import type { ImageRole, OptionKind } from "@/lib/catalog/model";
import { IMAGE_BUCKET, productImagePath, validateImageFile } from "@/lib/catalog/images";

/**
 * Write side of the product catalogue.
 *
 * business_id is never read from the form. It comes from requireTenant() (via
 * loadCatalogContext) which re-proves the membership against PostgreSQL on every request,
 * and RLS re-checks it again on the row. The role checks below only exist to return a
 * readable message before the database refuses — they are not the security boundary.
 */

function fail(error: string): ActionState {
  return { error, ok: false };
}

const DONE: ActionState = { error: null, ok: true };

const NO_PERMISSION = "Bu işlem için yetkiniz yok.";

function text(formData: FormData, key: string): string {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function optionalText(formData: FormData, key: string): string | null {
  const value = text(formData, key);
  return value.length > 0 ? value : null;
}

function uuidOrNull(formData: FormData, key: string): string | null {
  const value = text(formData, key);
  return /^[0-9a-fA-F-]{36}$/.test(value) ? value : null;
}

function isProductStatus(value: string): value is ProductStatus {
  return value === "draft" || value === "active" || value === "archived";
}

function isVariantStatus(value: string): value is VariantStatus {
  return value === "active" || value === "archived";
}

function isOptionKind(value: string): value is OptionKind {
  return value === "color" || value === "size" || value === "other";
}

/** Optional model / style code: trimmed, at most 64 characters, never a uniqueness rule. */
function styleCode(formData: FormData): string | null | undefined {
  const raw = formData.get("style_code");
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (value.length > 64) return undefined;
  return value.length > 0 ? value : null;
}

// ------------------------------------------------------------------ products

export async function createProductAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const name = text(formData, "name");
  const skuPrefix = text(formData, "sku_prefix");
  const priceInput = text(formData, "default_sale_price");
  const status = text(formData, "status");

  if (name.length < 2) return fail("Ürün adı en az 2 karakter olmalı.");
  if (name.length > 200) return fail("Ürün adı en fazla 200 karakter olabilir.");
  if (!skuPrefix) return fail("SKU ön eki zorunlu.");
  if (skuPrefix.length > 32) return fail("SKU ön eki en fazla 32 karakter olabilir.");

  const price = parseMoney(priceInput);
  if (price === null) return fail("Satış fiyatı geçerli bir tutar olmalı (örn. 1250,00).");

  // tax_rate / is_tax_inclusive are deliberately not sent: the pilot tax rate is not
  // settled yet, so the catalogue must not invent one. The column defaults apply.
  const { data, error } = await supabase
    .from("products")
    .insert({
      business_id: businessId,
      name,
      sku_prefix: skuPrefix,
      default_sale_price: price,
      status: isProductStatus(status) ? status : "draft",
      category_id: uuidOrNull(formData, "category_id"),
      brand_id: uuidOrNull(formData, "brand_id"),
      collection: optionalText(formData, "collection"),
      description: optionalText(formData, "description"),
      style_code: styleCode(formData) ?? null,
    })
    .select("id")
    .single();

  if (error) return fail(reportDbError("createProduct", error));

  revalidatePath("/app/urunler");
  redirect(`/app/urunler/${data.id as string}`);
}

export async function updateProductAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const productId = uuidOrNull(formData, "product_id");
  if (!productId) return fail("Ürün bulunamadı.");

  const name = text(formData, "name");
  const skuPrefix = text(formData, "sku_prefix");
  const status = text(formData, "status");

  if (name.length < 2) return fail("Ürün adı en az 2 karakter olmalı.");
  if (!skuPrefix) return fail("SKU ön eki zorunlu.");
  if (!isProductStatus(status)) return fail("Geçersiz durum.");

  const price = parseMoney(text(formData, "default_sale_price"));
  if (price === null) return fail("Satış fiyatı geçerli bir tutar olmalı (örn. 1250,00).");

  // tax_rate / is_tax_inclusive are intentionally absent from the update so an existing
  // value is preserved untouched rather than overwritten by a catalogue screen.
  const { error } = await supabase
    .from("products")
    .update({
      name,
      sku_prefix: skuPrefix,
      default_sale_price: price,
      status,
      category_id: uuidOrNull(formData, "category_id"),
      brand_id: uuidOrNull(formData, "brand_id"),
      collection: optionalText(formData, "collection"),
      description: optionalText(formData, "description"),
      style_code: styleCode(formData) ?? null,
      updated_at: new Date().toISOString(),
    })
    .eq("business_id", businessId)
    .eq("id", productId);

  if (error) return fail(reportDbError("updateProduct", error));

  revalidatePath("/app/urunler");
  revalidatePath(`/app/urunler/${productId}`);
  return DONE;
}

// ------------------------------------------------------------------ brands

export async function createBrandAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const name = text(formData, "brand_name");
  if (name.length < 2) return fail("Marka adı en az 2 karakter olmalı.");

  const { error } = await supabase.from("brands").insert({ business_id: businessId, name });
  if (error) return fail(reportDbError("createBrand", error));

  revalidatePath("/app/urunler");
  return DONE;
}

// ------------------------------------------------------------------ options

export async function createOptionAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const name = text(formData, "option_name");
  if (name.length < 1) return fail("Seçenek adı zorunlu.");
  const kindInput = text(formData, "option_kind");
  const kind: OptionKind = isOptionKind(kindInput) ? kindInput : "other";

  const { error } = await supabase
    .from("product_options")
    .insert({ business_id: businessId, name, kind, sort_order: kind === "color" ? 10 : kind === "size" ? 20 : 100 });

  if (error) return fail(reportDbError("createOption", error));

  revalidatePath("/app/urunler", "layout");
  return DONE;
}

/** Adds a value (a new size, a new colour) to an existing option. */
export async function createOptionValueAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const optionId = uuidOrNull(formData, "product_option_id");
  const value = text(formData, "option_value");
  if (!optionId) return fail("Seçenek bulunamadı.");
  if (!value) return fail("Değer zorunlu.");
  if (value.length > 60) return fail("Değer en fazla 60 karakter olabilir.");

  const code = optionalText(formData, "option_code");
  if (code && code.length > 16) return fail("Kısa kod en fazla 16 karakter olabilir.");
  const hexRaw = optionalText(formData, "color_hex");
  const colorHex = hexRaw ? (/^#[0-9a-fA-F]{6}$/.test(hexRaw) ? hexRaw.toLowerCase() : undefined) : null;
  if (colorHex === undefined) return fail("Renk kodu #RRGGBB biçiminde olmalı.");
  // Next position in this option's run, read from the database at write time so two
  // values added in quick succession never share an order (S, L, M was observed live).
  const { data: last } = await supabase
    .from("option_values")
    .select("sort_order")
    .eq("product_option_id", optionId)
    .order("sort_order", { ascending: false })
    .limit(1)
    .maybeSingle();
  const sortOrder = ((last?.sort_order as number | undefined) ?? 0) + 10;

  // business_id is filled by trg_bid_option_values from the parent option.
  const { error } = await supabase
    .from("option_values")
    .insert({ product_option_id: optionId, value, sort_order: sortOrder, code, color_hex: colorHex });

  if (error) return fail(reportDbError("createOptionValue", error));

  revalidatePath("/app/urunler", "layout");
  return DONE;
}

// ------------------------------------------------------------------ variants

export async function createVariantAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const productId = uuidOrNull(formData, "product_id");
  if (!productId) return fail("Ürün bulunamadı.");

  const sku = text(formData, "sku");
  if (!sku) return fail("SKU zorunlu.");
  if (sku.length > 64) return fail("SKU en fazla 64 karakter olabilir.");

  const optionValueIds = formData
    .getAll("option_value_ids")
    .filter((entry): entry is string => typeof entry === "string" && entry.length === 36);

  const overrideInput = text(formData, "sale_price_override");
  let override: number | null = null;
  if (overrideInput) {
    override = parseMoney(overrideInput);
    if (override === null) return fail("Varyant fiyatı geçerli bir tutar olmalı.");
  }

  // rpc_create_variant computes the option fingerprint and inserts the variant plus its
  // option rows in one transaction, so a duplicate combination is rejected by the database
  // rather than by a check we could race.
  const { error } = await supabase.rpc("rpc_create_variant", {
    p_product_id: productId,
    p_sku: sku,
    p_option_value_ids: optionValueIds,
    p_sale_price_override: override,
  });

  if (error) return fail(reportDbError("createVariant", error));

  revalidatePath(`/app/urunler/${productId}`);
  revalidatePath("/app/urunler");
  return DONE;
}

export async function updateVariantAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const variantId = uuidOrNull(formData, "variant_id");
  const productId = uuidOrNull(formData, "product_id");
  if (!variantId || !productId) return fail("Varyant bulunamadı.");

  const sku = text(formData, "sku");
  if (!sku) return fail("SKU zorunlu.");

  const status = text(formData, "status");
  if (!isVariantStatus(status)) return fail("Geçersiz varyant durumu.");

  const overrideInput = text(formData, "sale_price_override");
  let override: number | null = null;
  if (overrideInput) {
    override = parseMoney(overrideInput);
    if (override === null) return fail("Varyant fiyatı geçerli bir tutar olmalı.");
  }

  const { error } = await supabase
    .from("product_variants")
    .update({ sku, status, sale_price_override: override, updated_at: new Date().toISOString() })
    .eq("business_id", businessId)
    .eq("id", variantId);

  if (error) return fail(reportDbError("updateVariant", error));

  revalidatePath(`/app/urunler/${productId}`);
  revalidatePath("/app/urunler");
  return DONE;
}

// ------------------------------------------------------------------ barcodes

/** Records a barcode that already exists on the garment (supplier / EAN label). */
export async function addBarcodeAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, caps } = await loadCatalogContext();
  if (!caps.canManageBarcodes) return fail(NO_PERMISSION);

  const variantId = uuidOrNull(formData, "variant_id");
  const productId = uuidOrNull(formData, "product_id");
  if (!variantId || !productId) return fail("Varyant bulunamadı.");

  const barcode = text(formData, "barcode");
  if (barcode.length < 3 || barcode.length > 64) {
    return fail("Barkod 3 ile 64 karakter arasında olmalı.");
  }

  const symbology = text(formData, "symbology") || "CODE128";
  if (symbology === "EAN13" && !/^\d{13}$/.test(barcode)) {
    return fail("EAN13 barkodu tam 13 rakam olmalı.");
  }

  const makePrimary = formData.get("is_primary") === "on";

  // uix_barcode_primary is a partial unique index: the current primary has to be cleared
  // first. These are two statements, not one transaction — see the note in the Phase 2 report.
  if (makePrimary) {
    const { error: clearError } = await supabase
      .from("barcodes")
      .update({ is_primary: false })
      .eq("variant_id", variantId)
      .eq("is_primary", true);

    if (clearError) return fail(reportDbError("clearPrimaryBarcode", clearError));
  }

  // business_id is filled by trg_bid_barcodes from the parent variant.
  const { error } = await supabase.from("barcodes").insert({
    variant_id: variantId,
    barcode,
    barcode_type: "supplier",
    symbology,
    is_primary: makePrimary,
  });

  if (error) return fail(reportDbError("addBarcode", error));

  revalidatePath(`/app/urunler/${productId}`);
  return DONE;
}

/** Generates a business-scoped Code128 barcode for a variant that arrived without one. */
export async function generateInternalBarcodeAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, caps } = await loadCatalogContext();
  if (!caps.canManageBarcodes) return fail(NO_PERMISSION);

  const variantId = uuidOrNull(formData, "variant_id");
  const productId = uuidOrNull(formData, "product_id");
  if (!variantId || !productId) return fail("Varyant bulunamadı.");

  const { error } = await supabase.rpc("rpc_assign_internal_barcode", {
    p_variant_id: variantId,
    p_make_primary: formData.get("make_primary") === "on",
  });

  if (error) return fail(reportDbError("generateInternalBarcode", error));

  revalidatePath(`/app/urunler/${productId}`);
  return DONE;
}

export async function setPrimaryBarcodeAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canManageBarcodes) return fail(NO_PERMISSION);

  const barcodeId = uuidOrNull(formData, "barcode_id");
  const variantId = uuidOrNull(formData, "variant_id");
  const productId = uuidOrNull(formData, "product_id");
  if (!barcodeId || !variantId || !productId) return fail("Barkod bulunamadı.");

  const { error: clearError } = await supabase
    .from("barcodes")
    .update({ is_primary: false })
    .eq("business_id", businessId)
    .eq("variant_id", variantId)
    .eq("is_primary", true);

  if (clearError) return fail(reportDbError("clearPrimaryBarcode", clearError));

  const { error } = await supabase
    .from("barcodes")
    .update({ is_primary: true })
    .eq("business_id", businessId)
    .eq("id", barcodeId);

  if (error) return fail(reportDbError("setPrimaryBarcode", error));

  revalidatePath(`/app/urunler/${productId}`);
  return DONE;
}

export async function deleteBarcodeAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canManageBarcodes) return fail(NO_PERMISSION);

  const barcodeId = uuidOrNull(formData, "barcode_id");
  const productId = uuidOrNull(formData, "product_id");
  if (!barcodeId || !productId) return fail("Barkod bulunamadı.");

  const { error } = await supabase
    .from("barcodes")
    .delete()
    .eq("business_id", businessId)
    .eq("id", barcodeId);

  if (error) return fail(reportDbError("deleteBarcode", error));

  revalidatePath(`/app/urunler/${productId}`);
  return DONE;
}

// ------------------------------------------------------------------ variant matrix

export type MatrixCombo = { sku: string; option_value_ids: string[]; enabled: boolean };

/**
 * Generates every enabled combination of a matrix in one transaction through
 * rpc_generate_variants: duplicates of an existing active combination are reported, not
 * created; nothing is written when any combination is invalid.
 */
export async function generateVariantsAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const productId = uuidOrNull(formData, "product_id");
  if (!productId) return fail("Ürün bulunamadı.");

  let combos: MatrixCombo[];
  try {
    const parsed: unknown = JSON.parse(text(formData, "combos") || "[]");
    if (!Array.isArray(parsed)) return fail("Matris okunamadı.");
    combos = parsed
      .filter((c): c is MatrixCombo => typeof c === "object" && c !== null && typeof (c as MatrixCombo).sku === "string")
      .filter((c) => c.enabled !== false);
  } catch {
    return fail("Matris okunamadı.");
  }

  if (combos.length === 0) return fail("En az bir kombinasyon seçin.");
  if (combos.length > 500) return fail("Tek seferde en fazla 500 kombinasyon oluşturulabilir.");
  for (const c of combos) {
    if (!c.sku.trim() || c.sku.length > 64) return fail("Her kombinasyonun 64 karakteri geçmeyen bir SKU'su olmalı.");
    if (!Array.isArray(c.option_value_ids) || c.option_value_ids.some((id) => !/^[0-9a-fA-F-]{36}$/.test(id))) {
      return fail("Matris okunamadı.");
    }
  }

  const { data, error } = await supabase.rpc("rpc_generate_variants", {
    p_product_id: productId,
    p_combos: combos.map((c) => ({ sku: c.sku.trim(), option_value_ids: c.option_value_ids })),
  });
  if (error) return fail(reportDbError("generateVariants", error));

  const rows = (data ?? []) as Array<{ created: boolean }>;
  const created = rows.filter((r) => r.created).length;
  const skipped = rows.length - created;

  revalidatePath(`/app/urunler/${productId}`);
  revalidatePath("/app/urunler");
  return {
    error: null,
    ok: true,
    message: `${created} varyant oluşturuldu${skipped > 0 ? `, ${skipped} kombinasyon zaten vardı` : ""}.`,
  };
}

// ------------------------------------------------------------------ product lifecycle

/** Archive, never delete: sales, receipts and stock history point at the variants. */
export async function archiveProductAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const productId = uuidOrNull(formData, "product_id");
  if (!productId) return fail("Ürün bulunamadı.");
  const next = text(formData, "status") === "active" ? "active" : "archived";

  const { error } = await supabase
    .from("products")
    .update({ status: next, updated_at: new Date().toISOString() })
    .eq("business_id", businessId)
    .eq("id", productId);
  if (error) return fail(reportDbError("archiveProduct", error));

  revalidatePath(`/app/urunler/${productId}`);
  revalidatePath("/app/urunler");
  return DONE;
}

// ------------------------------------------------------------------ images

function isUploadRole(value: string): value is Extract<ImageRole, "product_main" | "product_gallery" | "variant" | "label_tag"> {
  return value === "product_main" || value === "product_gallery" || value === "variant" || value === "label_tag";
}

/**
 * Uploads one image for a product. The file is validated (type, size) before anything
 * is written; the object path is generated server-side under this business's prefix and
 * the storage policies re-check the tenant on the write. The row is inserted only after
 * the object exists; if the row is refused the object is removed again.
 */
export async function uploadImageAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const productId = uuidOrNull(formData, "product_id");
  if (!productId) return fail("Ürün bulunamadı.");
  const roleInput = text(formData, "role");
  if (!isUploadRole(roleInput)) return fail("Geçersiz görsel türü.");
  const variantId = uuidOrNull(formData, "variant_id");
  if (roleInput === "variant" && !variantId) return fail("Varyant görseli için bir varyant seçin.");

  const fileEntry = formData.get("file");
  const file = fileEntry instanceof File ? fileEntry : null;
  const check = validateImageFile(file);
  if (!check.ok) return fail(check.error);

  const path = productImagePath(businessId, productId, check.ext);
  const bytes = new Uint8Array(await file!.arrayBuffer());

  const upload = await supabase.storage.from(IMAGE_BUCKET).upload(path, bytes, { contentType: check.mime, upsert: false });
  if (upload.error) {
    console.error("[catalog] image upload refused:", upload.error.message);
    return fail("Görsel yüklenemedi. Yetkinizi ve dosyayı kontrol edin.");
  }

  // A first main image is simply the main image; a later one goes through rpc_set_main_image.
  const { data: existingMain } = await supabase
    .from("product_images")
    .select("id")
    .eq("business_id", businessId)
    .eq("product_id", productId)
    .eq("role", "product_main")
    .maybeSingle();
  const role: ImageRole = roleInput === "product_main" && existingMain ? "product_gallery" : roleInput;

  const { data: row, error } = await supabase
    .from("product_images")
    .insert({
      product_id: productId,
      variant_id: roleInput === "variant" ? variantId : null,
      role,
      storage_path: path,
      mime_type: check.mime,
      byte_size: file!.size,
      alt_text: optionalText(formData, "alt_text"),
      sort_order: 100,
    })
    .select("id")
    .single();

  if (error) {
    await supabase.storage.from(IMAGE_BUCKET).remove([path]);
    return fail(reportDbError("uploadImage", error));
  }

  if (roleInput === "product_main" && existingMain) {
    const { error: mainError } = await supabase.rpc("rpc_set_main_image", { p_image_id: row.id as string });
    if (mainError) return fail(reportDbError("setMainImage", mainError));
  }

  revalidatePath(`/app/urunler/${productId}`);
  revalidatePath("/app/urunler");
  return { error: null, ok: true, message: "Görsel yüklendi." };
}

export async function setMainImageAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const imageId = uuidOrNull(formData, "image_id");
  const productId = uuidOrNull(formData, "product_id");
  if (!imageId || !productId) return fail("Görsel bulunamadı.");

  const { error } = await supabase.rpc("rpc_set_main_image", { p_image_id: imageId });
  if (error) return fail(reportDbError("setMainImage", error));

  revalidatePath(`/app/urunler/${productId}`);
  revalidatePath("/app/urunler");
  return DONE;
}

/** Removes the row, then the object. Both writes are tenant-checked by RLS. */
export async function deleteImageAction(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const imageId = uuidOrNull(formData, "image_id");
  const productId = uuidOrNull(formData, "product_id");
  if (!imageId || !productId) return fail("Görsel bulunamadı.");

  const { data: row, error: readError } = await supabase
    .from("product_images")
    .select("storage_path")
    .eq("business_id", businessId)
    .eq("id", imageId)
    .maybeSingle();
  if (readError) return fail(reportDbError("deleteImage", readError));
  if (!row) return fail("Görsel bulunamadı.");

  const { error } = await supabase.from("product_images").delete().eq("business_id", businessId).eq("id", imageId);
  if (error) return fail(reportDbError("deleteImage", error));

  if (row.storage_path) {
    const removed = await supabase.storage.from(IMAGE_BUCKET).remove([row.storage_path as string]);
    if (removed.error) console.error("[catalog] image object not removed:", removed.error.message);
  }

  revalidatePath(`/app/urunler/${productId}`);
  revalidatePath("/app/urunler");
  return DONE;
}

