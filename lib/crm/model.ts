import type { UserRole } from "@/lib/roles";
import type { CountVariant } from "@/lib/stock/count-model";

/**
 * Customer CRM + reservations (Phase 10A). Customer rows are personal data: the reads
 * here are for owner / manager / sales_staff (the people who serve and sell) and are
 * always tenant-scoped by RLS. No cost, MWA or COGS crosses this module; the manager-only
 * profitability line on the customer page is loaded separately and only for that role.
 */

export type CrmCaps = {
  /** owner | manager | sales_staff — read / search / create / edit customers, hold and cancel reservations */
  canAccessCrm: boolean;
  /** owner | manager — may confirm an intentional duplicate customer, sees revenue / COGS on the customer page */
  canManage: boolean;
};
export function crmCaps(role: UserRole): CrmCaps {
  const managerPlus = role === "owner" || role === "manager";
  return { canAccessCrm: managerPlus || role === "sales_staff", canManage: managerPlus };
}

export type CustomerSource = { code: string; label: string };

export type Customer = {
  id: string;
  full_name: string;
  phone: string | null;
  email: string | null;
  instagram: string | null;
  source: string | null;
  notes: string | null;
  is_active: boolean;
  order_count: number;
  last_purchase_at: string | null;
  created_at: string;
};

export type CustomerHit = Pick<Customer, "id" | "full_name" | "phone" | "email" | "instagram" | "source" | "is_active" | "order_count" | "last_purchase_at">;
export type DuplicateHit = { id: string; full_name: string; phone: string | null; email: string | null; instagram: string | null; match: "phone" | "email" | "instagram" };

export type CustomerInput = {
  full_name: string;
  phone: string | null;
  email: string | null;
  instagram: string | null;
  source: string | null;
  notes: string | null;
  /** manager+: the duplicate warning was read and the person is a different one */
  confirm_duplicate: boolean;
};

export type CustomerSale = {
  id: string;
  sale_number: string;
  status: "completed" | "voided";
  occurred_at: string;
  branch_name: string;
  total: number;
  item_count: number;
  items_summary: string;
  returns: Array<{ id: string; return_number: string; return_type: string }>;
};
export type CustomerReservation = {
  id: string;
  reservation_number: string;
  status: ReservationStatus;
  expires_at: string;
  created_at: string;
  item_count: number;
};
/** manager+ only, real data from sale_costs (never sent to sales_staff) */
export type CustomerFinancials = { revenue: number; cogs: number; gross_margin: number; sales: number };

export type ReservationStatus = "active" | "converted" | "cancelled" | "expired";
export const RESERVATION_STATUS_LABELS: Record<ReservationStatus, string> = {
  active: "Aktif", converted: "Teslim edildi", cancelled: "İptal", expired: "Süresi doldu",
};

export type ReservationLine = { variant: CountVariant; quantity: number; price: number; available: number };
export type Reservation = {
  id: string;
  reservation_number: string;
  status: ReservationStatus;
  branch_id: string;
  branch_name: string;
  customer: { id: string; full_name: string; phone: string | null } | null;
  source: string | null;
  expires_at: string;
  note: string | null;
  created_at: string;
  created_by_name: string | null;
  cancelled_at: string | null;
  cancel_reason: string | null;
  fulfilled_at: string | null;
  converted_to_sale_id: string | null;
  converted_sale_number: string | null;
  items: ReservationLine[];
  /** the row is still active but the clock has passed: availability no longer counts it */
  is_past_due: boolean;
};

export type ReservationInput = {
  branch_id: string;
  customer_id: string;
  items: Array<{ variant_id: string; quantity: number }>;
  expires_at: string | null;
  note: string | null;
  source: string | null;
};
