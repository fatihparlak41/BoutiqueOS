import type { UserRole } from "@/lib/roles";
import type { CountVariant } from "@/lib/stock/count-model";

/**
 * POS (Phase 9A) shapes. Everything a cashier sees is selling-side data: list price,
 * available quantity, the cart, payments. Purchase cost, MWA and COGS never enter this
 * module — the database keeps them manager+ and the POS never asks for them.
 */

export type PaymentMethod = "cash" | "card" | "other";
export const PAYMENT_METHODS: PaymentMethod[] = ["cash", "card", "other"];
export const PAYMENT_LABELS: Record<PaymentMethod, string> = { cash: "Nakit", card: "Kart", other: "Diğer" };

export type Register = {
  id: string;
  branch_id: string;
  name: string;
  is_active: boolean;
  device_ref: string | null;
  /** The register's open session, if any (one at most). */
  open_session: RegisterSession | null;
};

export type RegisterSession = {
  id: string;
  cash_register_id: string;
  session_number: string;
  status: "open" | "closed";
  opened_by: string;
  opened_by_name: string | null;
  opened_at: string;
};

/** A sellable variant as the POS shows it: identity + list price + what is available here. */
export type PosItem = CountVariant & {
  /** Server list price (variant override or product default), TRY. */
  price: number;
  /** sellable − active reservations at the terminal's branch (display; the sale re-checks under lock). */
  available: number;
};

export type PosMember = { user_id: string; full_name: string | null; can_sell: boolean; is_self: boolean };
export type PosCustomer = { id: string; full_name: string | null; phone: string };

export type CartLine = {
  item: PosItem;
  quantity: number;
  /** Selling price actually charged per unit; ≤ item.price. */
  unit_price: number;
};

export type SalePayload = {
  register_session_id: string;
  client_transaction_id: string;
  lines: Array<{ variant_id: string; quantity: number; unit_price: number; expected_list_price: number }>;
  payments: Array<{ method: PaymentMethod; amount: number }>;
  customer_id: string | null;
  salesperson_id: string | null;
  note: string | null;
  /** an ACTIVE reservation being fulfilled by this sale (converted in the same transaction) */
  reservation_id: string | null;
};

/** A reservation handed to the terminal: its lines are pre-loaded and pinned, its customer is the sale's customer. */
export type PosReservation = {
  id: string;
  reservation_number: string;
  expires_at: string;
  customer: PosCustomer | null;
  lines: Array<{ item: PosItem; quantity: number }>;
};

export type SaleResult = { sale_id: string; sale_number: string; total: number; change_given: number; replayed: boolean };

export type SaleReceipt = {
  id: string;
  sale_number: string;
  status: "completed" | "voided";
  occurred_at: string;
  branch_name: string;
  cashier_name: string | null;
  salesperson_name: string | null;
  salesperson_is_cashier: boolean;
  customer: PosCustomer | null;
  subtotal: number;
  discount_amount: number;
  total: number;
  change_given: number;
  note: string | null;
  items: Array<{ id: string; variant: CountVariant; quantity: number; list_price: number; unit_price: number; discount_amount: number; line_total: number }>;
  payments: Array<{ id: string; method: PaymentMethod | "bank_transfer"; amount: number; currency: string }>;
};

export type PosCaps = {
  /** owner | manager | sales_staff — may open the POS and complete sales */
  canSell: boolean;
  /** owner | manager — create registers, open and close drawers (the server enforces the same) */
  canManageRegisters: boolean;
  /** owner | manager: unlimited; sales_staff: business_members.max_discount_pct > 0 */
  canDiscount: boolean;
  /** owner | manager — complete a return / exchange (financial reversal); sales_staff only prepares */
  canCompleteReturns: boolean;
  /** 0–100; the server enforces it, the UI only stops obvious mistakes early */
  maxDiscountPct: number;
};

export function posCaps(role: UserRole, maxDiscountPct: number): PosCaps {
  const managerPlus = role === "owner" || role === "manager";
  const seller = managerPlus || role === "sales_staff";
  return {
    canSell: seller,
    canManageRegisters: managerPlus,
    canDiscount: managerPlus || (role === "sales_staff" && maxDiscountPct > 0),
    canCompleteReturns: managerPlus,
    maxDiscountPct: managerPlus ? 100 : maxDiscountPct,
  };
}

export function lineTotal(line: CartLine): number {
  return round2(line.quantity * line.unit_price);
}
export function cartTotal(lines: CartLine[]): number {
  return round2(lines.reduce((s, l) => s + lineTotal(l), 0));
}
export function round2(n: number): number {
  return Math.round(n * 100) / 100;
}
