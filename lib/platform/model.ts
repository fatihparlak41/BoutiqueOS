import type { ApplicationStatus, BillingInterval, BillingInvoice, BillingSubscription, BusinessStatus, InvoiceStatus, PaymentMethod, SubscriptionStatus } from "@/lib/saas/model";

/** Shapes returned by the rpc_platform_* reads (JSONB, platform admin only). */

export type PlatformPlanRef = { code: string; name: string; price_amount: number; currency: string; billing_interval: BillingInterval } | null;

export type PlatformApplicationRow = {
  id: string;
  status: ApplicationStatus;
  business_name: string;
  country: string;
  currency: string;
  submitted_at: string;
  reviewed_at: string | null;
  business_id: string | null;
  applicant: { name: string | null; email: string | null; confirmed: boolean };
  plan: PlatformPlanRef;
};

export type PlatformApplicationList = { rows: PlatformApplicationRow[]; total: number; limit: number; offset: number; pending: number };

export type PlatformApplicationDetail = {
  id: string;
  status: ApplicationStatus;
  business_name: string;
  country: string;
  currency: string;
  phone: string | null;
  business_type: string | null;
  branch_name: string;
  submitted_at: string;
  reviewed_at: string | null;
  review_note: string | null;
  reviewer: string | null;
  business_id: string | null;
  business: { id: string; name: string; code: string; status: BusinessStatus } | null;
  applicant: { user_id: string; name: string | null; email: string | null; confirmed_at: string | null; other_memberships: number };
  plan: (NonNullable<PlatformPlanRef> & { id: string }) | null;
  subscription: { id: string; status: SubscriptionStatus; starts_at: string | null; ends_at: string | null; activated_at: string | null } | null;
};

export type PlatformBusinessRow = {
  id: string;
  name: string;
  code: string;
  status: BusinessStatus;
  base_currency: string;
  created_at: string;
  owners: number;
  members: number;
  branches: number;
  subscription: { id: string; status: SubscriptionStatus; plan: string; ends_at: string | null } | null;
};

export type PlatformBusinessList = { rows: PlatformBusinessRow[]; total: number; limit: number; offset: number };

export type PlatformSubscription = {
  id: string;
  status: SubscriptionStatus;
  plan: string;
  plan_code: string;
  price_amount: number;
  currency: string;
  billing_interval: BillingInterval;
  starts_at: string | null;
  ends_at: string | null;
  renews_at: string | null;
  activated_at: string | null;
  cancelled_at: string | null;
  source: string;
  note: string | null;
  cancel_at_period_end: boolean;
  lapsed: boolean;
  latest_invoice: LatestInvoice | null;
  invoice_count: number;
};

/** The newest live (non-void) invoice of a subscription, as the lists and the business page show it. */
export type LatestInvoice = {
  id: string;
  invoice_number: string;
  status: InvoiceStatus;
  total: number;
  currency: string;
  amount_paid: number;
  due_at: string;
  overdue: boolean;
  billing_period_start?: string;
  billing_period_end?: string;
};

export type PlatformBusinessDetail = {
  id: string;
  name: string;
  code: string;
  status: BusinessStatus;
  base_currency: string;
  created_at: string;
  timezone: string | null;
  owners: Array<{ name: string | null; email: string | null }>;
  members: number;
  branches: number;
  subscriptions: PlatformSubscription[];
  application: { id: string; status: ApplicationStatus; submitted_at: string } | null;
  audit: Array<{ at: string; action: string; admin: string | null; payload: Record<string, unknown> }>;
};

export type PlatformPlan = {
  id: string;
  code: string;
  name: string;
  description: string | null;
  billing_interval: BillingInterval;
  price_amount: number;
  currency: string;
  is_active: boolean;
  sort_order: number;
  subscriptions: number;
};

export const PAGE_SIZE = 25;

export const AUDIT_ACTION_LABELS: Record<string, string> = {
  approve_application: "Başvuru onaylandı",
  reject_application: "Başvuru reddedildi",
  set_business_status: "İşletme durumu değişti",
  set_subscription_status: "Abonelik durumu değişti",
  upsert_plan: "Plan güncellendi",
  issue_invoice: "Fatura kesildi",
  record_payment: "Ödeme kaydedildi",
  void_invoice: "Fatura iptal edildi",
  cancel_subscription: "Abonelik iptali",
  billing_sweep: "Faturalama taraması",
  set_billing_setting: "Faturalama ayarı değişti",
};

/** Payload keys shown in the audit table, in reading order (from → to first). */
export const AUDIT_PAYLOAD_KEYS = ["from", "to", "mode", "reason", "note", "plan", "code", "invoice_number", "amount", "currency", "method", "reference", "key"] as const;

// ---------------------------------------------------------------- billing console (Phase 13B)

export type PlatformBillingOverview = {
  settings: { invoice_due_days: number; billing_grace_days: number };
  invoices: { open: number; overdue: number; paid_30d: number; void: number };
  open_totals: Record<string, number>;
  paid_30d_totals: Record<string, number>;
  subscriptions: Partial<Record<SubscriptionStatus, number>>;
  awaiting_first_invoice: number;
  renewal_due_30d: number;
  lapsed: number;
  scheduled_cancellations: number;
};

export type PlatformInvoiceRow = BillingInvoice & { business: { id: string; name: string; code: string }; subscription_id: string };
export type PlatformInvoiceList = { rows: PlatformInvoiceRow[]; total: number; limit: number; offset: number };

export type PlatformPayment = {
  id: string;
  amount: number;
  currency: string;
  method: PaymentMethod;
  status: "recorded" | "reversed";
  reference: string;
  paid_at: string;
  note: string | null;
  recorded_at: string;
  recorded_by: string | null;
};

export type PlatformInvoiceDetail = BillingInvoice & {
  business: { id: string; name: string; code: string; status: BusinessStatus };
  subscription: BillingSubscription;
  issued_by: string | null;
  voided_by: string | null;
  items: Array<{ line_no: number; description: string; quantity: number; unit_amount: number; line_total: number }>;
  payments: PlatformPayment[];
};

export type PlatformSubscriptionRow = BillingSubscription & {
  business: { id: string; name: string; code: string; status: BusinessStatus };
  latest_invoice: LatestInvoice | null;
  invoice_count: number;
};
export type PlatformSubscriptionList = { rows: PlatformSubscriptionRow[]; total: number; limit: number; offset: number };

/** List filters accepted by the RPCs; "overdue" and "lapsed" are derived views, not stored states. */
export const INVOICE_FILTERS = ["open", "overdue", "paid", "void"] as const;
export const SUBSCRIPTION_FILTERS = ["pending", "active", "past_due", "cancelled", "expired", "lapsed"] as const;
export type InvoiceFilter = (typeof INVOICE_FILTERS)[number];
export type SubscriptionFilter = (typeof SUBSCRIPTION_FILTERS)[number];
export const INVOICE_FILTER_LABELS: Record<InvoiceFilter, string> = { open: "Ödeme bekliyor", overdue: "Vadesi geçmiş", paid: "Ödendi", void: "İptal" };
export const SUBSCRIPTION_FILTER_LABELS: Record<SubscriptionFilter, string> = { pending: "Ödeme bekliyor", active: "Aktif", past_due: "Gecikmiş", cancelled: "İptal", expired: "Süresi doldu", lapsed: "Dönemi bitmiş" };

export function pageOffset(page: string | undefined): number {
  const n = Number.parseInt(page ?? "1", 10);
  return Number.isFinite(n) && n > 1 ? (n - 1) * PAGE_SIZE : 0;
}
