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

/**
 * RAISE EXCEPTION prefixes used by the SECURITY DEFINER RPCs (…0004, …062632 and the
 * phase 4 invitation RPCs). Order matters: the invitation prefixes contain the generic
 * NOT_FOUND / FORBIDDEN words and are matched first. None of these sentences says
 * whether an account exists.
 */
const RPC_MESSAGES: Array<[string, string]> = [
  ["INVITE_NOT_FOUND", "Bu davet bulunamadı. Bağlantıyı e-postadan yeniden açmayı deneyin."],
  ["INVITE_EMAIL_MISMATCH", "Bu davet başka bir e-posta adresi için gönderilmiş. Davetin gönderildiği adresle oturum açın."],
  ["INVITE_REVOKED", "Bu davet geri çekilmiş. Yeni bir davet için işletme yöneticinize başvurun."],
  ["INVITE_ALREADY_USED", "Bu davet daha önce kullanılmış."],
  ["INVITE_EXPIRED", "Bu davetin süresi dolmuş. İşletme yöneticinizden yeni bir davet isteyin."],
  ["INVITE_ALREADY_PENDING", "Bu adres için zaten bekleyen bir davet var."],
  ["MEMBER_INACTIVE_USE_REACTIVATE", "Bu işletmedeki üyeliğiniz kapatılmış. İşletme sahibi yeniden açabilir."],
  ["EMAIL_NOT_CONFIRMED", "Önce e-posta adresinizi doğrulayın; davet e-postasındaki bağlantı bunu yapar."],
  ["ALREADY_MEMBER", "Bu adres zaten bu işletmenin aktif üyesi."],
  // stock counts (20260915150000) — matched before the generic prefixes below
  ["STALE_COUNT", "Stok sayım sırasında değişti. Farkları yeniden hesaplayın."],
  ["ALREADY_POSTED", "Bu sayım zaten işlendi; ikinci kez işlenemez."],
  ["UNRESOLVED_LINES", "Sayılmamış satırlar var. Her satırı sayın ya da \"0 adet olarak doğrula\" ile onaylayın."],
  ["COST_REQUIRED: surplus", "Fazla çıkan bir varyantın devralacağı maliyet yok (şubede stoğu yok). Önce maliyetini çözün; sayım işlenmedi."],
  ["INVALID_EVENT", "Sayım olayı tanımlanamadı. Sayfayı yenileyip tekrar deneyin."],
  ["INVALID_QTY", "Geçersiz miktar."],
  ["INVALID_STATE: stock count", "Sayım bu durumda bu işlemi kabul etmiyor. Sayfayı yenileyin."],
  // goods receiving + landed cost (20260916090000)
  ["NOT_REVIEWED", "Belge işlenmeden önce gözden geçirilmeli. Önce \"Gözden geçir\" adımını çalıştırın."],
  ["STALE_DRAFT", "Belge gözden geçirildikten sonra değişti. Yeniden gözden geçirin."],
  // purchase orders (20260918100000)
  ["OVER_RECEIPT", "Bu belge siparişte kalan miktarı aşıyor. Adetleri kalan miktara indirin ya da siparişi düzeltin."],
  ["NOT_IN_PO", "Belgede siparişte olmayan bir varyant var. Satırı silin ya da siparişsiz bir mal kabul açın."],
  ["PO_NOT_OPEN", "Bu sipariş açık değil; mal kabul ona bağlanamaz ya da işlenemez."],
  ["PO_SUPPLIER_MISMATCH", "Mal kabulün tedarikçisi siparişin tedarikçisiyle aynı değil."],
  ["OPEN_RECEIPTS", "Bu siparişe bağlı taslak mal kabul var. Önce onu iptal edin ya da işleyin."],
  ["NOTHING_REMAINING", "Siparişin tamamı teslim alındı; kalan miktar yok."],
  ["REASON_REQUIRED", "Bir neden yazın (en az 3 karakter)."],
  ["EMPTY_DOCUMENT", "Belgede satır yok."],
  ["INVALID_PO", "Sipariş bu işletmede bulunamadı."],
  ["ALREADY_REVERSED", "Bu belge zaten ters kaydedilmiş."],
  ["this business requires a return reason", "Bu işletmede iade nedeni zorunlu."],
  ["REASON_REQUIRED", "Ters kayıt nedeni en az 3 karakter olmalı."],
  ["CHARGE_CURRENCY", "Fatura tedarikçisine yazılan masraf fatura para biriminde olmalı. Masrafı ayrı tedarikçiye yazın ya da para birimini değiştirin."],
  ["ALLOCATION_BASIS", "Tüm satırların maliyeti 0 iken masraflar tutara orantılı dağıtılamaz. Adede orantılı ya da eşit dağıtım seçin."],
  ["has fewer than", "Mallar kısmen çıkmış; belge ters kaydedilemez. Tedarikçi iadesi ya da düzeltme kullanın."],
  ["have no purchase cost", "Fiyatı girilmemiş satırlar var; önce her satıra birim maliyet girin."],
  ["purchase cost is entered by", "Birim maliyeti yalnız işletme sahibi ya da yönetici girebilir."],
  ["charge allocation is set by", "Dağıtım yöntemini yalnız işletme sahibi ya da yönetici değiştirebilir."],
  ["INVALID_COST", "Birim maliyet negatif olamaz."],
  // customers / reservations (20260916210000 + Rev 3 reservations)
  ["INSUFFICIENT_AVAILABLE_STOCK", "Yeterli müsait stok yok: ürün başka bir rezervasyonda ya da satılmış olabilir."],
  ["RESERVATION_NOT_ACTIVE", "Rezervasyon artık aktif değil (teslim edilmiş, iptal ya da süresi dolmuş)."],
  ["RESERVATION_MISMATCH", "Sepet rezervasyondaki her ürünü en az ayrılan adette içermeli."],
  ["INVALID_RESERVATION", "Rezervasyon bulunamadı ya da bu şubeye ait değil."],
  ["RESERVATION_EXPIRED", "Rezervasyonun süresi dolmuş; yeni bir rezervasyon açın."],
  ["INVALID_EXPIRY", "Son tarih ileride ve en fazla 90 gün sonrası olmalı."],
  ["EMPTY_RESERVATION", "Rezervasyon için en az bir ürün seçin."],
  ["INVALID_SOURCE", "Kaynak tanınmadı. Listeden seçin."],
  ["chk_customer_email", "E-posta biçimi geçersiz."],
  ["chk_customer_name", "Ad Soyad gerekli."],
  ["INVALID_STATE: reservation", "Rezervasyon bu durumda değiştirilemez."],
  // returns / exchange (20260916190000 + Rev 3 return core) — operator wording, never DB text
  ["EXCHANGE_WINDOW_EXPIRED", "Değişim süresi dolmuş."],
  ["FINAL_SALE", "Bu ürün değişim kapsamı dışında."],
  ["OVER_RETURN", "Bu ürün için iade edilebilir adet kalmadı."],
  ["EXCHANGE_DOWNGRADE_BLOCKED", "Yeni ürün iade edilen üründen ucuz; bu işletmede fark iadesi yapılamıyor. Eşit ya da daha pahalı bir ürün seçin."],
  ["EXCHANGE_NOT_ALLOWED", "Bu işletmede değişim kapalı."],
  ["REFUND_NOT_ALLOWED", "Bu işletmede para iadesi yapılamıyor; yalnız değişim mümkün."],
  ["STORE_CREDIT_NOT_ALLOWED", "Bu işletmede mağaza kredisi kapalı."],
  ["REFUND_METHOD_REQUIRED", "İade yöntemi seçilmeli."],
  ["INVALID_REASON", "İade nedeni tanınmadı. Listeden seçin."],
  ["sale_item not on sale", "İade satırı bu satışa ait değil."],
  ["USE_EXCHANGE_RPC", "Değişim, değişim akışıyla tamamlanmalı."],
  ["EMPTY_RETURN", "İade edilecek ürün seçilmedi."],
  ["DISPOSITION_NOT_AUTHORIZED", "Bu durum seçimi için yetkiniz yok."],
  ["VOID_BLOCKED", "Bu satış iptal edilemez (iadesi var ya da kasa oturumu kapalı)."],
  ["BRANCH_MISMATCH", "Satış başka bir şubeye ait; değişim o şubenin kasasında yapılmalı."],
  ["cash refund needs an open register session", "Nakit iade için açık bir kasa oturumu gerekir."],
  // POS (20260916140000 + Rev 3 sale core)
  ["stock_staff cannot complete sales", "Depo rolü satış tamamlayamaz."],
  ["CLIENT_TRANSACTION_REQUIRED", "Satış kimliği eksik. Sayfayı yenileyip tekrar deneyin."],
  ["INVALID_REGISTER_SESSION", "Kasa oturumu bulunamadı ya da bu şubeye ait değil."],
  ["REGISTER_CLOSED", "Kasa oturumu kapalı. Önce kasayı açın."],
  ["REGISTER_REQUIRED", "Satış için açık bir kasa oturumu gerekir."],
  ["REGISTER_ALREADY_OPEN", "Bu kasanın zaten açık bir oturumu var."],
  ["INVALID_REGISTER", "Kasa bulunamadı ya da pasif."],
  ["INVALID_SALESPERSON", "Seçilen kişi bu işletmede satış yapabilen aktif bir üye değil."],
  ["INVALID_CUSTOMER", "Müşteri bulunamadı."],
  ["VARIANT_NOT_SELLABLE", "Ürün ya da varyant satışa kapalı (arşivlenmiş)."],
  ["PRICE_CHANGED", "Fiyat değişti. Ürünü sepetten çıkarıp yeniden ekleyin."],
  ["INVALID_PRICE", "Birim fiyat liste fiyatının üstünde ya da negatif olamaz."],
  ["DISCOUNT_NOT_AUTHORIZED", "Bu indirimi uygulama yetkiniz yok."],
  ["available=", "Yeterli satılabilir stok yok. Sepeti mevcut adede göre düzeltin."],
  ["EMPTY_CART", "Sepet boş."],
  ["DUPLICATE_ITEM", "Aynı varyant sepette iki kez var; satırları birleştirin."],
  ["INVALID_ITEM", "Sepet satırı geçersiz."],
  ["PAYMENT_SHORT", "Ödeme toplamı satış tutarından az."],
  ["PAYMENT_MISMATCH", "Fazla ödeme yalnız nakitle para üstü olarak verilebilir."],
  ["INVALID_PAYMENT", "Ödeme tutarı sıfırdan büyük olmalı."],
  ["CURRENCY_NOT_ACCEPTED", "Bu para birimi kabul edilmiyor."],
  ["IDEMPOTENCY_CONFLICT", "Bu satış kimliği başka bir sepetle kullanılmış. Sayfayı yenileyin."],
  ["SETTING_MISSING", "İşletme ayarı eksik. Yönetici işletme ayarlarını tamamlamalı."],
  ["COUNT_REQUIRED", "Kasa kapanışı için sayılan nakit gerekli."],
  ["INVALID_STATE: session", "Kasa oturumu zaten kapalı."],
  ["INVALID_STATE: receipt", "Belge bu durumda bu işlemi kabul etmiyor (ör. zaten işlenmiş). Sayfayı yenileyin."],
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

  // Named RPC exceptions first: several of them are raised with the 42501 code (an
  // invitation for another address, an unconfirmed account) and deserve their own
  // sentence rather than the generic "no permission".
  for (const [needle, message] of RPC_MESSAGES) {
    if (raw.includes(needle)) return message;
  }

  // Plain RLS rejection ("permission denied", "row-level security") carries no prefix.
  if (code === "42501") return FORBIDDEN;

  if (code === "23505") {
    for (const [constraint, message] of Object.entries(UNIQUE_MESSAGES)) {
      if (raw.includes(constraint)) return message;
    }
    return "Bu kayıt zaten mevcut.";
  }

  if (code === "23503") return "Seçilen kayıt artık mevcut değil. Sayfayı yenileyip tekrar deneyin.";
  if (code === "23514") return "Girilen değer kabul edilen aralığın dışında.";

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
