/**
 * Single translator from PostgreSQL / PostgREST failures to sentences a shop manager
 * can act on. Shared by the catalogue, receiving and stock modules.
 *
 * The raw message is never shown: it leaks constraint and column names, and in the RLS
 * case it would tell a user exactly which policy rejected them. Anything unrecognised
 * becomes one generic sentence and is logged server-side instead.
 */

export type DbError = {
  code?: string | null;
  message?: string | null;
  details?: string | null;
};

const GENERIC = "İşlem tamamlanamadı. Lütfen tekrar deneyin.";
const FORBIDDEN = "Bu işlem için yetkiniz yok.";

/** Constraint name -> message. Names come from the applied migrations. */
const UNIQUE_MESSAGES: Record<string, string> = {
  // catalogue (20260908000001)
  products_business_id_sku_prefix_key: "Bu SKU ön eki bu işletmede zaten kullanılıyor.",
  product_variants_business_id_sku_key: "Bu SKU zaten başka bir varyantta kullanılıyor.",
  uix_variant_active_fingerprint: "Bu seçenek kombinasyonu bu üründe zaten var.",
  barcodes_business_id_barcode_key: "Bu barkod bu işletmede zaten kayıtlı.",
  uix_barcode_primary: "Bu varyantın zaten bir birincil barkodu var.",
  brands_business_id_name_key: "Bu marka adı zaten var.",
  product_options_business_id_name_key: "Bu seçenek adı zaten var.",
  option_values_product_option_id_value_key: "Bu değer bu seçenekte zaten var.",
  categories_business_id_slug_key: "Bu kategori zaten var.",
  // receiving (20260908000001)
  suppliers_business_id_name_key: "Bu isimde bir tedarikçi zaten var.",
  goods_receipts_business_id_receipt_number_key: "Bu belge numarası zaten kullanılmış.",
  goods_receipt_items_goods_receipt_id_variant_id_key:
    "Bu varyant belgede zaten var. Yeni satır yerine mevcut satırın adedini güncelleyin.",
};

/** RAISE EXCEPTION prefixes used by the SECURITY DEFINER RPCs (…0004 and …062632). */
const RPC_MESSAGES: Array<[string, string]> = [
  ["INVALID_PRODUCT", "Ürün bulunamadı."],
  ["INVALID_OPTION_VALUE", "Seçilen seçenek değerlerinden biri bu işletmeye ait değil."],
  ["INVALID_VARIANT", "Varyant bulunamadı."],
  ["INVALID_BRANCH", "Seçilen şube bu işletmede aktif değil."],
  ["INVALID_SUPPLIER", "Seçilen tedarikçi bu işletmede aktif değil."],
  ["INVALID_CURRENCY", "Desteklenmeyen para birimi."],
  ["INVALID_FX", "Kur geçersiz. TRY belgelerde kur 1 olmalı, diğerlerinde sıfırdan büyük olmalı."],
  ["INVALID_DATE", "Tarih geçersiz."],
  ["EMPTY_DOCUMENT", "Belgede hiç satır yok. En az bir varyant ekleyin."],
  ["INVALID_STATE", "Bu belge artık taslak değil; işlem uygulanamaz."],
  ["NOT_FOUND", "Kayıt bulunamadı."],
  ["NOT_IMPLEMENTED", "Bu işlem henüz uygulanmadı."],
  ["IMMUTABLE", "İşlenmiş belge değiştirilemez."],
  ["COST_REQUIRED", "Bu işlem için birim maliyet gerekli."],
  ["NEGATIVE_POOL", "Bu işlem stoğu eksiye düşürürdü."],
  ["INSUFFICIENT_STOCK", "Yeterli stok yok."],
  ["FX_RATE_MISSING", "Bu tarih için tanımlı kur yok."],
  ["UNAUTHENTICATED", "Oturumunuz düşmüş. Yeniden giriş yapın."],
  ["FORBIDDEN", FORBIDDEN],
];

export function toUserMessage(error: DbError | null | undefined): string {
  if (!error) return GENERIC;

  const code = error.code ?? "";
  const raw = `${error.message ?? ""} ${error.details ?? ""}`;

  // RLS rejection and the explicit role guards inside SECURITY DEFINER RPCs.
  if (code === "42501") return FORBIDDEN;

  if (code === "23505") {
    for (const [constraint, message] of Object.entries(UNIQUE_MESSAGES)) {
      if (raw.includes(constraint)) return message;
    }
    return "Bu kayıt zaten mevcut.";
  }

  if (code === "23503") return "Seçilen kayıt artık mevcut değil. Sayfayı yenileyip tekrar deneyin.";
  if (code === "23514") return "Girilen değer kabul edilen aralığın dışında.";

  for (const [needle, message] of RPC_MESSAGES) {
    if (raw.includes(needle)) return message;
  }

  return GENERIC;
}

/**
 * Logs the untranslated failure for the operator and returns the safe message.
 * Call this in every server action so nothing is swallowed silently.
 */
export function reportDbError(context: string, error: DbError | null | undefined): string {
  console.error(`[db] ${context}:`, error?.code, error?.message, error?.details);
  return toUserMessage(error);
}
