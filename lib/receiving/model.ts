import type { UserRole } from "@/lib/tenant";

/**
 * Receiving vocabulary shared by server queries and client forms.
 *
 * The unions mirror the enums from migration 20260908000001 — goods_receipt_status,
 * supplier_status and the iso_currency domain. Nothing here is invented.
 */

export type ReceiptStatus = "draft" | "posted" | "cancelled";
export type SupplierStatus = "active" | "inactive";
export type Currency = "TRY" | "GBP" | "EUR" | "USD";

export const RECEIPT_STATUS_LABELS: Record<ReceiptStatus, string> = {
  draft: "Taslak",
  posted: "İşlendi",
  cancelled: "İptal",
};

export const SUPPLIER_STATUS_LABELS: Record<SupplierStatus, string> = {
  active: "Aktif",
  inactive: "Pasif",
};

/** iso_currency domain: CHECK (VALUE IN ('TRY','GBP','EUR','USD')). */
export const CURRENCIES: Currency[] = ["TRY", "GBP", "EUR", "USD"];

export const BASE_CURRENCY: Currency = "TRY";

export type Supplier = {
  id: string;
  name: string;
  code: string | null;
  currency: Currency;
  status: SupplierStatus;
  contact_name: string | null;
  phone: string | null;
  email: string | null;
  city: string | null;
  country: string;
  notes: string | null;
};

export type ReceiptListRow = {
  id: string;
  receipt_number: string;
  received_at: string;
  status: ReceiptStatus;
  invoice_currency: Currency;
  exchange_rate: number;
  document_ref: string | null;
  supplier_name: string;
  branch_name: string;
  line_count: number;
  total_quantity: number;
  /**
   * Sum of quantity * unit_cost in the invoice currency (rpc_goods_receipt_list_totals).
   * null when the caller may not see cost (stock_staff) — never a masked 0.
   */
  total_original: number | null;
  /** Lines still waiting for a manager's price (manager+ only, else 0). */
  missing_cost_lines: number;
  posted_at: string | null;
  created_at: string;
};

export type ReceiptLine = {
  id: string;
  variant_id: string;
  product_name: string;
  sku: string;
  options: string;
  primary_barcode: string | null;
  quantity: number;
  /**
   * Purchase cost in the invoice currency. null = not priced yet (stock_staff recorded the
   * line) OR the caller may not see cost; `ReceiptDetail.cost_visible` tells which.
   */
  unit_cost: number | null;
  /** Written by rpc_post_goods_receipt; null while the receipt is a draft. */
  fx_rate_snapshot: number | null;
  unit_cost_base: number | null;
  total_cost_base: number | null;
  /** Landed cost, written at POST (Phase 8A): allocated eligible charges and the resulting unit cost. */
  allocated_charge_base: number | null;
  landed_unit_cost_base: number | null;
  landed_total_cost_base: number | null;
};

/** goods_receipt_charges.kind */
export type ChargeKind = "freight" | "customs" | "insurance" | "handling" | "other";
export const CHARGE_KIND_LABELS: Record<ChargeKind, string> = {
  freight: "Nakliye",
  customs: "Gümrük",
  insurance: "Sigorta",
  handling: "Elleçleme",
  other: "Diğer",
};

/** goods_receipt_charges.liability_mode — who is owed the charge. */
export type ChargeLiabilityMode = "add_to_invoice" | "separate_supplier" | "no_liability";
export const CHARGE_LIABILITY_LABELS: Record<ChargeLiabilityMode, string> = {
  add_to_invoice: "Fatura tedarikçisine borç (aynı para birimi)",
  separate_supplier: "Başka tedarikçiye borç",
  no_liability: "Borç yazma (ödendi / gider)",
};

/** goods_receipts.allocation_method — how eligible charges spread over the lines. */
export type AllocationMethod = "invoice_value_proportional" | "quantity_proportional" | "equal_per_line" | "manual";
export const ALLOCATION_LABELS: Record<AllocationMethod, string> = {
  invoice_value_proportional: "Fatura tutarına orantılı",
  quantity_proportional: "Adede orantılı",
  equal_per_line: "Satır başına eşit",
  manual: "Elle (henüz açık değil)",
};

export type ReceiptCharge = {
  id: string;
  kind: ChargeKind;
  description: string | null;
  amount: number;
  currency: Currency;
  exchange_rate: number;
  amount_base: number;
  include_in_landed: boolean;
  liability_mode: ChargeLiabilityMode;
  payee_supplier_id: string | null;
  payee_supplier_name: string | null;
};

/** One row of the allocation preview / review (rpc_goods_receipt_preview / _review). */
export type AllocationRow = {
  item_id: string;
  variant_id: string;
  quantity: number;
  unit_cost: number;
  unit_cost_base: number;
  total_cost_base: number;
  allocated_charge_base: number;
  landed_unit_cost_base: number;
  landed_total_cost_base: number;
};

export type AllocationPreview = {
  lines: AllocationRow[];
  /** The stored review still describes the document exactly as it is now. */
  review_current: boolean;
  reviewed_at: string | null;
  /** Translated reason the allocation cannot be computed (ALLOCATION_BASIS, manual method …). */
  error: string | null;
};

export type ReceiptReversal = {
  id: string;
  reason: string;
  reversed_at: string;
  reversed_by_name: string | null;
  /** Manager+ only (column privilege); null for stock_staff. */
  value_removed_base: number | null;
};

export type ReceiptDetail = {
  id: string;
  receipt_number: string;
  received_at: string;
  status: ReceiptStatus;
  invoice_currency: Currency;
  exchange_rate: number;
  document_ref: string | null;
  note: string | null;
  supplier_id: string;
  supplier_name: string;
  branch_id: string;
  branch_name: string;
  posted_at: string | null;
  created_at: string;
  lines: ReceiptLine[];
  /**
   * true when the caller is owner|manager and every cost field below is real data
   * (rpc_goods_receipt_financial). false for stock_staff: all cost fields are null and
   * `charges` is empty because the database refused them, not because the UI hid them.
   */
  cost_visible: boolean;
  /** Lines without a purchase cost (manager+ only; 0 otherwise). */
  missing_cost_lines: number;
  /** Phase 8A */
  allocation_method: AllocationMethod;
  reviewed_at: string | null;
  charges: ReceiptCharge[];
  posted_invoice_total_original: number | null;
  posted_charges_base: number | null;
  posted_landed_total_base: number | null;
  reversal: ReceiptReversal | null;
};

/** A variant offered in the line picker. */
export type PickableVariant = {
  variant_id: string;
  product_id: string;
  product_name: string;
  sku: string;
  options: string;
  primary_barcode: string | null;
};

export type ReceivingCaps = {
  /** suppliers / goods_receipts / goods_receipt_items (operational columns) SELECT => fn_is_procurement */
  canRead: boolean;
  /** suppliers write => fn_is_manager_plus */
  canWriteSupplier: boolean;
  /** draft create, header, quantities, cancel => owner | manager | stock_staff */
  canWriteReceipt: boolean;
  /**
   * Purchase cost, charges, allocation, review, POST, financial reads
   * (rpc_goods_receipt_financial / _list_totals, cost columns, goods_receipt_charges) => owner | manager
   */
  canManageCost: boolean;
  /** variant_cost_pools / inventory_movement_costs SELECT => fn_is_manager_plus */
  canSeePoolCost: boolean;
  /** rpc_reverse_goods_receipt => owner | manager */
  canReverse: boolean;
};

/**
 * Mirrors the database rules so a screen is hidden when the database would refuse it.
 * Hiding is a courtesy; column privileges, RLS and the RPC role guards are the boundary
 * (20260916120000: stock_staff records quantities, never sees or enters a price).
 */
export function receivingCaps(role: UserRole): ReceivingCaps {
  const procurement = role === "owner" || role === "manager" || role === "stock_staff";
  const managerPlus = role === "owner" || role === "manager";
  return {
    canRead: procurement,
    canWriteSupplier: managerPlus,
    canWriteReceipt: procurement,
    canManageCost: managerPlus,
    canSeePoolCost: managerPlus,
    canReverse: managerPlus,
  };
}

/** Result envelope for the line picker's server action. */
export type VariantSearchState = {
  error: string | null;
  term: string;
  results: PickableVariant[];
};

export const VARIANT_SEARCH_IDLE: VariantSearchState = { error: null, term: "", results: [] };
