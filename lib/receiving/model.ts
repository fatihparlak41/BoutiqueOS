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
  /** Sum of quantity * unit_cost in the invoice currency, computed from the lines. */
  total_original: number;
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
  unit_cost: number;
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
  value_removed_base: number;
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
  /** suppliers / goods_receipts / goods_receipt_items SELECT => fn_is_procurement */
  canRead: boolean;
  /** suppliers write => fn_is_manager_plus */
  canWriteSupplier: boolean;
  /** draft create + line writes + posting => owner | manager | stock_staff */
  canWriteReceipt: boolean;
  /** variant_cost_pools / inventory_movement_costs SELECT => fn_is_manager_plus */
  canSeePoolCost: boolean;
  /** rpc_reverse_goods_receipt => owner | manager */
  canReverse: boolean;
};

/**
 * Mirrors the RLS predicates so a screen is hidden when the database would refuse it.
 * Hiding is a courtesy; RLS and the RPC role guards are the boundary.
 *
 * Note stock_staff: it may read goods_receipt_items.unit_cost (pol_gri_select is
 * fn_is_procurement) but not variant_cost_pools — that split is deliberate.
 */
export function receivingCaps(role: UserRole): ReceivingCaps {
  const procurement = role === "owner" || role === "manager" || role === "stock_staff";
  const managerPlus = role === "owner" || role === "manager";
  return {
    canRead: procurement,
    canWriteSupplier: managerPlus,
    canWriteReceipt: procurement,
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
