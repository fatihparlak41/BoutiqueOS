import type { PaymentMethod } from "@/lib/pos/model";

/**
 * Returns / exchange (Phase 9B) shapes. Everything here is receipt-level data: the sale,
 * its lines at the prices the customer paid, what may still come back and why not.
 * Historical COGS and the cost-pool never reach this module — the reversal record
 * (return_item_costs) is manager+ in the database and no screen asks for it.
 */

export type ReturnPolicy = {
  allow_exchange: boolean;
  allow_cash_refund: boolean;
  allow_store_credit: boolean;
  exchange_window_days: number;
  receipt_required: boolean;
  reason_required: boolean;
  downgrade_treatment: "block" | "cash_refund" | "store_credit";
  window_expired: boolean;
  days_left: number;
};

export type LineStatus = "ELIGIBLE" | "WINDOW_EXPIRED" | "EXCLUDED" | "NOTHING_LEFT" | "SALE_VOIDED";

/** Operator wording for every eligibility outcome — no raw codes on screen. */
export const LINE_STATUS_TEXT: Record<LineStatus, string> = {
  ELIGIBLE: "Değişim için uygun",
  WINDOW_EXPIRED: "Değişim süresi dolmuş",
  EXCLUDED: "Bu ürün değişim kapsamı dışında",
  NOTHING_LEFT: "Bu ürün için iade edilebilir adet kalmadı",
  SALE_VOIDED: "Satış iptal edilmiş",
};

export type EligibilityLine = {
  sale_item_id: string;
  variant_id: string;
  sku: string;
  product_name: string;
  options: string | null;
  quantity: number;
  returned_quantity: number;
  returnable_quantity: number;
  unit_price_at_sale: number;
  list_price: number;
  status: LineStatus;
  excluded_by: "product" | "category" | null;
};

export type ReturnReason = { code: string; label: string };

export type Eligibility = {
  sale: {
    id: string;
    sale_number: string;
    status: "completed" | "voided";
    occurred_at: string;
    branch_id: string;
    branch_name: string;
    total: number;
    customer_id: string | null;
    customer_name: string | null;
    customer_phone: string | null;
    exchange_group_id: string | null;
  };
  policy: ReturnPolicy;
  returns: Array<{ id: string; return_number: string; return_type: ReturnType; credit_value_base: number; refund_amount_base: number; created_at: string; replacement_sale_id: string | null }>;
  reasons: ReturnReason[];
  lines: EligibilityLine[];
};

export type FoundSale = {
  id: string;
  sale_number: string;
  status: "completed" | "voided";
  occurred_at: string;
  total: number;
  branch_id: string;
  customer_name: string | null;
  customer_phone: string | null;
  item_count: number;
  returned_count: number;
  is_exchange_replacement: boolean;
};

export type LookupMode = "sale_number" | "barcode" | "customer";
export type ReturnType = "exchange" | "refund" | "store_credit";
export type Condition = "sellable" | "quarantine" | "damaged";
export const CONDITIONS: Condition[] = ["quarantine", "sellable", "damaged"];
export const CONDITION_LABELS: Record<Condition, string> = { quarantine: "Karantina (incelenecek)", sellable: "Satılabilir", damaged: "Hasarlı" };

/** What the operator selected to come back: per sale line, quantity and physical condition. */
export type ReturnSelection = { sale_item_id: string; quantity: number; condition: Condition };

export type ReturnPayload = {
  sale_id: string;
  client_transaction_id: string;
  items: ReturnSelection[];
  refund_method: PaymentMethod | null;
  reason_code: string | null;
  note: string | null;
  register_session_id: string | null;
};

export type ExchangePayload = {
  register_session_id: string;
  sale_id: string;
  client_transaction_id: string;
  return_items: ReturnSelection[];
  new_lines: Array<{ variant_id: string; quantity: number; unit_price: number; expected_list_price: number }>;
  payments: Array<{ method: PaymentMethod; amount: number }>;
  reason_code: string | null;
  note: string | null;
  customer_id: string | null;
  salesperson_id: string | null;
};

export type ReturnResult = { return_id: string; return_number: string; credit_value_base: number; refund_amount_base: number; replayed: boolean };
export type ExchangeResult = ReturnResult & { sale_id: string; sale_number: string; total: number; amount_due: number; change_given: number; credit_applied: number };

export type ReturnDocument = {
  id: string;
  return_number: string;
  return_type: ReturnType;
  created_at: string;
  original_sale_id: string;
  original_sale_number: string;
  replacement_sale_id: string | null;
  replacement_sale_number: string | null;
  credit_value_base: number;
  refund_amount_base: number;
  refund_method: PaymentMethod | "bank_transfer" | null;
  reason_code: string | null;
  reason_label: string | null;
  note: string | null;
  processed_by_name: string | null;
  branch_name: string;
  customer: { id: string; full_name: string | null; phone: string } | null;
  items: Array<{ id: string; variant_id: string; sku: string; product_name: string; quantity: number; disposition: Condition; unit_price_at_sale: number }>;
};

export const RETURN_TYPE_LABELS: Record<ReturnType, string> = { exchange: "Değişim", refund: "Para iadesi", store_credit: "Mağaza kredisi" };

export function selectionCredit(lines: EligibilityLine[], selection: ReturnSelection[]): number {
  return Math.round(selection.reduce((s, sel) => {
    const l = lines.find((x) => x.sale_item_id === sel.sale_item_id);
    return s + (l ? l.unit_price_at_sale * sel.quantity : 0);
  }, 0) * 100) / 100;
}
