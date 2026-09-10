/**
 * Tenant role vocabulary. Client-safe: no data access, no "server-only".
 *
 * It lives outside lib/tenant.ts because that module is server-only, and a client
 * component that needs the Turkish label for a role would otherwise drag the whole
 * tenant resolver — and its server-only guard — into the browser bundle.
 */
export type UserRole = "owner" | "manager" | "sales_staff" | "stock_staff";

export const ROLE_LABELS: Record<UserRole, string> = {
  owner: "Sahip",
  manager: "Yönetici",
  sales_staff: "Satış",
  stock_staff: "Depo",
};
