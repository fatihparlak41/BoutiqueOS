/**
 * Customer-facing wording for the public order RPCs (rpc_shop_create_order,
 * rpc_shop_cancel_order). The operational map in lib/db-errors.ts is written for merchants
 * (e.g. INVALID_NAME there means a business name); a shopper must never see that, nor any
 * raw code. Unknown errors fall back to one calm sentence. Server validation is unchanged —
 * this only chooses the words.
 */

type Err = { message?: string | null; details?: string | null; code?: string | null } | null | undefined;

const CHECKOUT: Array<[RegExp, string]> = [
  [/INVALID_NAME/, "Lütfen adınızı girin."],
  [/INVALID_PHONE/, "Lütfen geçerli bir telefon numarası girin."],
  [/INVALID_EMAIL/, "E-posta adresini kontrol edin."],
  [/STORE_UNAVAILABLE|ORDERS_DISABLED/, "Bu mağaza şu an online sipariş almıyor."],
  [/FULFILLMENT_UNAVAILABLE|NOT_IMPLEMENTED/, "Yalnız mağazadan teslim seçilebilir."],
  [/EMPTY_CART/, "Sepetin boş."],
  [/CART_LIMIT/, "Bir siparişte en fazla 20 farklı ürün ve toplam 30 adet olabilir."],
  [/INVALID_QTY/, "Ürün adetlerini kontrol edin."],
  [/CART_PROBLEMS|INSUFFICIENT|UNAVAILABLE/, "Bu ürün artık müsait değil."],
];

const CANCEL: Array<[RegExp, string]> = [
  [/CANCEL_NOT_ALLOWED|INVALID_STATE|ORDER_FINAL/, "Sipariş onaylandığı için buradan iptal edilemiyor. Lütfen mağazayla iletişime geçin."],
];

const FALLBACK_CHECKOUT = "Sipariş talebi şu an oluşturulamadı. Lütfen birazdan tekrar deneyin.";
const FALLBACK_CANCEL = "İptal şu an tamamlanamadı. Lütfen birazdan tekrar deneyin.";

function pick(err: Err, table: Array<[RegExp, string]>, fallback: string): string {
  const raw = `${err?.message ?? ""} ${err?.details ?? ""}`;
  for (const [re, msg] of table) if (re.test(raw)) return msg;
  return fallback;
}

export const checkoutErrorMessage = (err: Err): string => pick(err, CHECKOUT, FALLBACK_CHECKOUT);
export const cancelErrorMessage = (err: Err): string => pick(err, CANCEL, FALLBACK_CANCEL);
