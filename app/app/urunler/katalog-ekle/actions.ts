"use server";

import { revalidatePath } from "next/cache";
import {
  findSimilarProducts,
  getProduct,
  listProductOptions,
  loadCatalogContext,
  resolveBarcode,
  type BarcodeHit,
} from "@/lib/catalog/queries";
import { reportDbError } from "@/lib/catalog/errors";
import { parseMoney } from "@/lib/catalog/format";
import { IDLE } from "@/lib/catalog/action-state";
import { uploadImageAction } from "@/app/app/urunler/actions";
import type { CategoryRef, NamedRef, OptionKind, OptionValue, ProductDetail, ProductOption, ProductStatus } from "@/lib/catalog/model";
import {
  normalizeName,
  slugify,
  type DuplicateReport,
  type IntakeIdentity,
  type OnboardCombo,
  type OnboardResult,
  type OnboardVariantResult,
  type ProductSummary,
  type Result,
} from "@/lib/catalog/intake";

/**
 * Server side of the physical catalogue intake.
 *
 * Every function re-derives the tenant from the session (loadCatalogContext →
 * requireTenant) and passes that business id explicitly to the onboarding RPCs, which
 * prove membership against exactly that id again. Nothing here writes stock, cost or
 * receipts; the RPCs cannot (tests T62f) and no other table is touched.
 *
 * Results are plain data, never thrown errors: the wizard keeps its state and shows
 * the translated sentence.
 */

const NO_PERMISSION = "Bu işlem için yetkiniz yok.";
const UUID = /^[0-9a-fA-F-]{36}$/;

function fail<T>(error: string): Result<T> {
  return { ok: false, error };
}

// ------------------------------------------------------------------ lookups

/** Exact barcode / SKU match inside the caller's business; the hard stop of step 1. */
export async function lookupBarcodeAction(code: string): Promise<Result<BarcodeHit | null>> {
  const trimmed = code.trim();
  if (trimmed.length < 3 || trimmed.length > 64) return fail("Barkod 3 ile 64 karakter arasında olmalı.");
  try {
    return { ok: true, data: await resolveBarcode(trimmed) };
  } catch (error) {
    console.error("[intake] barcode lookup failed:", error instanceof Error ? error.message : error);
    return fail("Barkod sorgulanamadı. Tekrar deneyin.");
  }
}

function summarize(row: {
  id: string; name: string; style_code: string | null; sku_prefix: string; status: ProductStatus; category_id: string | null;
}, categories: NamedRef[], variantCounts: Map<string, number>): ProductSummary {
  return {
    id: row.id,
    name: row.name,
    style_code: row.style_code,
    sku_prefix: row.sku_prefix,
    status: row.status,
    category: categories.find((c) => c.id === row.category_id) ?? null,
    variant_count: variantCounts.get(row.id) ?? 0,
  };
}

async function summariesFor(ids: string[]): Promise<ProductSummary[]> {
  if (ids.length === 0) return [];
  const { supabase, businessId } = await loadCatalogContext();
  const [{ data: rows }, { data: variants }, { data: cats }] = await Promise.all([
    supabase.from("products").select("id, name, style_code, sku_prefix, status, category_id").eq("business_id", businessId).in("id", ids),
    supabase.from("product_variants").select("product_id").eq("business_id", businessId).in("product_id", ids).eq("status", "active"),
    supabase.from("categories").select("id, name").eq("business_id", businessId),
  ]);
  const counts = new Map<string, number>();
  for (const v of variants ?? []) counts.set(v.product_id as string, (counts.get(v.product_id as string) ?? 0) + 1);
  const categories = (cats ?? []).map((c) => ({ id: c.id as string, name: c.name as string }));
  return (rows ?? []).map((r) =>
    summarize(
      { id: r.id as string, name: r.name as string, style_code: r.style_code as string | null, sku_prefix: r.sku_prefix as string, status: r.status as ProductStatus, category_id: r.category_id as string | null },
      categories,
      counts,
    ),
  );
}

/**
 * Duplicate candidates before a new product is written. Style code: exact. Name:
 * normalised equality or prefix, computed here, deterministically — no fuzzy scoring.
 * The person decides; nothing is merged.
 */
export async function checkDuplicatesAction(input: { name: string; style_code: string }): Promise<Result<DuplicateReport>> {
  const name = input.name.trim();
  const styleCode = input.style_code.trim();
  if (name.length < 2) return fail("Ürün adı en az 2 karakter olmalı.");

  try {
    const { supabase, businessId } = await loadCatalogContext();
    const similar = await findSimilarProducts({ name, styleCode: styleCode || null });
    const styleIds = similar.filter((s) => s.reason === "style_code" && styleCode && s.style_code?.toLocaleLowerCase("tr-TR") === styleCode.toLocaleLowerCase("tr-TR")).map((s) => s.id);

    // Name candidates: the prefix hits findSimilarProducts already found plus every product
    // sharing the longest word of the name ("zz test satin dress" must not be skipped because
    // its first word is short). The deterministic rule then decides: same normalised name, or
    // one is the other's word-prefix.
    const wanted = normalizeName(name);
    const longestWord = wanted.split(" ").sort((a, b) => b.length - a.length)[0] ?? "";
    const candidates = new Map<string, string>();
    for (const s of similar) if (s.reason === "name") candidates.set(s.id, s.name);
    if (longestWord.length >= 3) {
      const { data } = await supabase
        .from("products")
        .select("id, name")
        .eq("business_id", businessId)
        .ilike("name", `%${longestWord.replace(/[,()*\\%]/g, " ")}%`)
        .limit(50);
      for (const r of data ?? []) candidates.set(r.id as string, r.name as string);
    }
    const nameIds: string[] = [];
    for (const [id, candidateName] of candidates) {
      const have = normalizeName(candidateName);
      if (have === wanted || have.startsWith(`${wanted} `) || wanted.startsWith(`${have} `)) nameIds.push(id);
    }

    const all = await summariesFor([...new Set([...styleIds, ...nameIds])]);
    return {
      ok: true,
      data: {
        style_matches: all.filter((p) => styleIds.includes(p.id)),
        name_matches: all.filter((p) => nameIds.includes(p.id) && !styleIds.includes(p.id)),
      },
    };
  } catch (error) {
    console.error("[intake] duplicate check failed:", error instanceof Error ? error.message : error);
    return fail("Benzer ürünler kontrol edilemedi. Tekrar deneyin.");
  }
}

/** Find an existing model to extend: by name, style code or SKU prefix. */
export async function searchProductsAction(term: string): Promise<Result<ProductSummary[]>> {
  const q = term.replace(/[,()*\\%]/g, " ").trim();
  if (q.length < 2) return { ok: true, data: [] };
  try {
    const { supabase, businessId } = await loadCatalogContext();
    const { data, error } = await supabase
      .from("products")
      .select("id")
      .eq("business_id", businessId)
      .neq("status", "archived")
      .or(`name.ilike.%${q}%,sku_prefix.ilike.%${q}%,style_code.ilike.%${q}%`)
      .order("name")
      .limit(12);
    if (error) return fail(reportDbError("intakeSearch", error));
    return { ok: true, data: await summariesFor((data ?? []).map((r) => r.id as string)) };
  } catch (error) {
    console.error("[intake] search failed:", error instanceof Error ? error.message : error);
    return fail("Arama yapılamadı. Tekrar deneyin.");
  }
}

/** The existing product with its variants, for "add the missing variant". RLS scopes it to the tenant. */
export async function loadProductAction(productId: string): Promise<Result<ProductDetail>> {
  if (!UUID.test(productId)) return fail("Ürün bulunamadı.");
  try {
    const product = await getProduct(productId);
    if (!product) return fail("Ürün bulunamadı.");
    return { ok: true, data: product };
  } catch (error) {
    console.error("[intake] product load failed:", error instanceof Error ? error.message : error);
    return fail("Ürün okunamadı. Tekrar deneyin.");
  }
}

// ------------------------------------------------------------------ vocabulary

/** The business's colour / size option, created with the Turkish default name when it has none yet. */
export async function ensureOptionAction(kind: Extract<OptionKind, "color" | "size">): Promise<Result<ProductOption>> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const existing = (await listProductOptions()).find((o) => o.kind === kind);
  if (existing) return { ok: true, data: existing };

  const name = kind === "color" ? "Renk" : "Beden";
  const { data, error } = await supabase
    .from("product_options")
    .insert({ business_id: businessId, name, kind, sort_order: kind === "color" ? 10 : 20 })
    .select("id, name, kind, sort_order")
    .single();
  if (error) return fail(reportDbError("intakeEnsureOption", error));

  revalidatePath("/app/urunler", "layout");
  return { ok: true, data: { id: data.id as string, name: data.name as string, kind, sort_order: data.sort_order as number, values: [] } };
}

/** A colour or size the garment physically has and the business did not list yet. */
export async function addOptionValueAction(input: {
  option_id: string; value: string; code: string; color_hex: string;
}): Promise<Result<OptionValue>> {
  const { supabase, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);
  if (!UUID.test(input.option_id)) return fail("Seçenek bulunamadı.");

  const value = input.value.trim();
  if (!value) return fail("Değer zorunlu.");
  if (value.length > 60) return fail("Değer en fazla 60 karakter olabilir.");
  const code = input.code.trim().toLocaleUpperCase("tr-TR") || null;
  if (code && code.length > 16) return fail("Kısa kod en fazla 16 karakter olabilir.");
  const hexRaw = input.color_hex.trim();
  if (hexRaw && !/^#[0-9a-fA-F]{6}$/.test(hexRaw)) return fail("Renk kodu #RRGGBB biçiminde olmalı.");

  // Same rule as createOptionValueAction: next position read at write time.
  const { data: last } = await supabase
    .from("option_values")
    .select("sort_order")
    .eq("product_option_id", input.option_id)
    .order("sort_order", { ascending: false })
    .limit(1)
    .maybeSingle();
  const sortOrder = ((last?.sort_order as number | undefined) ?? 0) + 10;

  const { data, error } = await supabase
    .from("option_values")
    .insert({ product_option_id: input.option_id, value, code, color_hex: hexRaw ? hexRaw.toLowerCase() : null, sort_order: sortOrder })
    .select("id, value, sort_order, code, color_hex")
    .single();
  if (error) return fail(reportDbError("intakeAddOptionValue", error));

  revalidatePath("/app/urunler", "layout");
  return {
    ok: true,
    data: { id: data.id as string, value: data.value as string, sort_order: data.sort_order as number, code: (data.code as string | null) ?? null, color_hex: (data.color_hex as string | null) ?? null },
  };
}

/** A category this business needs; a suggestion becomes a row only when someone picks it. */
export async function createCategoryAction(name: string): Promise<Result<CategoryRef>> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const trimmed = name.trim();
  if (trimmed.length < 2 || trimmed.length > 60) return fail("Kategori adı 2 ile 60 karakter arasında olmalı.");
  const slug = slugify(trimmed);
  if (!slug) return fail("Kategori adı harf ya da rakam içermeli.");

  // Never a near-duplicate: the same name after normalisation (case, spacing, punctuation)
  // is the existing category, active or not — the picker selects it instead.
  const { data: existing } = await supabase.from("categories").select("id, name, is_active").eq("business_id", businessId);
  const same = (existing ?? []).find((c) => normalizeName(c.name as string) === normalizeName(trimmed));
  if (same) {
    return fail(same.is_active ? `«${same.name}» adlı kategori zaten var; listeden seçin.` : `«${same.name}» adlı kategori daha önce kapatılmış; Ayarlar'dan yeniden açın.`);
  }

  const { data, error } = await supabase
    .from("categories")
    .insert({ business_id: businessId, name: trimmed, slug, sort_order: 100 })
    .select("id, name, parent_id")
    .single();
  if (error) return fail(reportDbError("intakeCreateCategory", error));

  revalidatePath("/app/urunler", "layout");
  return { ok: true, data: { id: data.id as string, name: data.name as string, parent_id: (data.parent_id as string | null) ?? null } };
}

// ------------------------------------------------------------------ writes

function validateCombos(combos: OnboardCombo[]): string | null {
  if (combos.length === 0) return "En az bir varyant seçin.";
  if (combos.length > 200) return "Tek seferde en fazla 200 varyant eklenebilir.";
  const seen = new Set<string>();
  for (const c of combos) {
    if (!c.sku.trim() || c.sku.length > 64) return "Her varyantın 64 karakteri geçmeyen bir SKU'su olmalı.";
    if (c.option_value_ids.some((id) => !UUID.test(id))) return "Matris okunamadı.";
    for (const b of c.barcodes) {
      const code = b.trim();
      if (!code) continue;
      if (code.length < 3 || code.length > 64) return `Barkod 3 ile 64 karakter arasında olmalı: ${code}`;
      if (seen.has(code)) return `Aynı barkod iki varyanta yazılmış: ${code}`;
      seen.add(code);
    }
  }
  return null;
}

function cleanCombos(combos: OnboardCombo[]): OnboardCombo[] {
  return combos.map((c) => ({
    sku: c.sku.trim(),
    option_value_ids: c.option_value_ids,
    barcodes: c.barcodes.map((b) => b.trim()).filter(Boolean),
  }));
}

function toVariantResults(rows: unknown): OnboardVariantResult[] {
  return ((rows ?? []) as Array<Record<string, unknown>>).map((r) => ({
    sku: String(r.sku),
    variant_id: String(r.variant_id),
    created: Boolean(r.created),
    barcodes_added: Number(r.barcodes_added ?? 0),
  }));
}

/**
 * New model + confirmed variants + label barcodes in one transaction
 * (rpc_onboard_product). The business id is the session's tenant, stated explicitly.
 */
export async function onboardProductAction(input: { identity: IntakeIdentity; combos: OnboardCombo[] }): Promise<Result<OnboardResult>> {
  const { supabase, businessId, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);

  const { identity } = input;
  const name = identity.name.trim();
  if (name.length < 2) return fail("Ürün adı en az 2 karakter olmalı.");
  if (name.length > 200) return fail("Ürün adı en fazla 200 karakter olabilir.");
  const prefix = identity.sku_prefix.trim();
  if (!prefix || prefix.length > 32) return fail("SKU ön eki 1 ile 32 karakter arasında olmalı.");
  const styleCode = identity.style_code.trim();
  if (styleCode.length > 64) return fail("Model kodu en fazla 64 karakter olabilir.");
  let price = "0";
  if (identity.price.trim()) {
    const parsed = parseMoney(identity.price);
    if (parsed === null) return fail("Satış fiyatı geçerli bir tutar olmalı (örn. 1250,00).");
    price = parsed.toFixed(2);
  }
  const categoryId = UUID.test(identity.category_id) ? identity.category_id : null;
  const brandId = UUID.test(identity.brand_id) ? identity.brand_id : null;

  const combos = cleanCombos(input.combos);
  const problem = validateCombos(combos);
  if (problem) return fail(problem);

  const { data, error } = await supabase.rpc("rpc_onboard_product", {
    p_business_id: businessId,
    p_product: { name, sku_prefix: prefix, style_code: styleCode || null, category_id: categoryId, brand_id: brandId, default_sale_price: price },
    p_combos: combos,
  });
  if (error) return fail(reportDbError("onboardProduct", error));

  const variants = toVariantResults(data);
  const productId = ((data ?? []) as Array<{ product_id?: string }>)[0]?.product_id;
  if (!productId) return fail("Ürün oluşturuldu ama kimliği okunamadı. Ürün listesini kontrol edin.");

  revalidatePath("/app/urunler");
  return { ok: true, data: { product_id: productId, variants } };
}

/** Missing combinations of an existing model, with their label barcodes; existing ones are skipped. */
export async function onboardVariantsAction(input: { product_id: string; combos: OnboardCombo[] }): Promise<Result<OnboardResult>> {
  const { supabase, caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) return fail(NO_PERMISSION);
  if (!UUID.test(input.product_id)) return fail("Ürün bulunamadı.");

  const combos = cleanCombos(input.combos);
  const problem = validateCombos(combos);
  if (problem) return fail(problem);

  const { data, error } = await supabase.rpc("rpc_onboard_variants", { p_product_id: input.product_id, p_combos: combos });
  if (error) return fail(reportDbError("onboardVariants", error));

  revalidatePath("/app/urunler");
  revalidatePath(`/app/urunler/${input.product_id}`);
  return { ok: true, data: { product_id: input.product_id, variants: toVariantResults(data) } };
}

/** One photo of the just-created product; same validation, path and rollback as the product page upload. */
export async function uploadIntakeImageAction(formData: FormData): Promise<Result<null>> {
  const state = await uploadImageAction(IDLE, formData);
  return state.error ? fail(state.error) : { ok: true, data: null };
}
