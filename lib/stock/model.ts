/**
 * Stock vocabulary. Client-safe: no data access, no "server-only".
 *
 * The bucket union is the inventory_bucket enum from migration 20260908000001. There is no
 * IN_TRANSIT bucket — goods in transit live in transfer_held_inventory, which is outside
 * this module. The movement reasons are the movement_reason enum, unchanged.
 */

export type Bucket = "sellable" | "quarantine" | "damaged";

export const BUCKET_LABELS: Record<Bucket, string> = {
  sellable: "Satılabilir",
  quarantine: "Karantina",
  damaged: "Hasarlı",
};

export type MovementReason =
  | "goods_receipt"
  | "sale"
  | "sale_void"
  | "customer_return"
  | "supplier_return"
  | "adjustment"
  | "state_change"
  | "transfer_ship"
  | "transfer_receive"
  | "write_off";

export const MOVEMENT_REASON_LABELS: Record<MovementReason, string> = {
  goods_receipt: "Mal kabul",
  sale: "Satış",
  sale_void: "Satış iptali",
  customer_return: "Müşteri iadesi",
  supplier_return: "Tedarikçi iadesi",
  adjustment: "Stok düzeltme",
  state_change: "Durum değişimi",
  transfer_ship: "Transfer çıkışı",
  transfer_receive: "Transfer girişi",
  write_off: "Zayi",
};

/** Operational filters over the aggregated quantities — not new buckets. */
export type StockState = "in_stock" | "out_of_stock" | "has_quarantine" | "has_damaged";

export const STOCK_STATE_LABELS: Record<StockState, string> = {
  in_stock: "Stokta",
  out_of_stock: "Tükenmiş",
  has_quarantine: "Karantinada var",
  has_damaged: "Hasarlı var",
};

export type StockRow = {
  variant_id: string;
  product_id: string;
  product_name: string;
  sku: string;
  options: string;
  primary_barcode: string | null;
  category_name: string | null;
  brand_name: string | null;
  branch_id: string;
  branch_name: string;
  sellable: number;
  quarantine: number;
  damaged: number;
  /** sellable + quarantine + damaged, aggregated from v_stock_by_bucket only. */
  on_hand: number;
  reserved: number;
  available: number;
};

export type MovementRow = {
  id: string;
  occurred_at: string;
  created_at: string;
  quantity: number;
  bucket: Bucket;
  reason: MovementReason;
  reference_type: string;
  reference_id: string;
  note: string | null;
  /** Filled for goods_receipt_item references so the row can link to its document. */
  receipt_id: string | null;
  receipt_number: string | null;
};
