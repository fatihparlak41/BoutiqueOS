/**
 * SaaS onboarding model shared by the public registration, the applicant pages and the
 * platform console. No Next, no "server-only": plain types and labels.
 *
 * Nothing here knows a price. Plans come from saas_plans; the interval and amount are
 * rendered from the row, never from a constant.
 */

export type BillingInterval = "monthly" | "annual";
export type ApplicationStatus = "pending" | "approved" | "rejected" | "withdrawn";
export type SubscriptionStatus = "pending" | "active" | "past_due" | "cancelled" | "expired";
export type BusinessStatus = "active" | "suspended" | "cancelled";

export type PublicPlan = {
  id: string;
  code: string;
  name: string;
  description: string | null;
  billing_interval: BillingInterval;
  price_amount: number;
  currency: string;
};

export type MyApplication = {
  application_id: string;
  status: ApplicationStatus;
  business_name: string;
  country: string;
  currency: string;
  submitted_at: string;
  reviewed_at: string | null;
  /** Only carried when rejected. */
  review_note: string | null;
  plan: { code: string; name: string; price_amount: number; currency: string; billing_interval: BillingInterval } | null;
  business_active: boolean | null;
};

export type MyOnboarding = {
  platform_admin: boolean;
  application: MyApplication | null;
  inactive_businesses: Array<{ name: string; status: BusinessStatus }>;
};

/** The draft the registration form stores in the signup metadata until the address is confirmed. */
export type ApplicationDraft = {
  business_name: string;
  country: string;
  currency: string;
  phone: string | null;
  business_type: string | null;
  plan_id: string | null;
};

export const COUNTRY_OPTIONS = [
  { value: "TR", label: "Türkiye" },
  { value: "CY", label: "Kıbrıs" },
  { value: "GB", label: "Birleşik Krallık" },
  { value: "DE", label: "Almanya" },
] as const;

export const CURRENCY_OPTIONS = [
  { value: "TRY", label: "TRY — Türk lirası" },
  { value: "EUR", label: "EUR — Euro" },
  { value: "USD", label: "USD — ABD doları" },
  { value: "GBP", label: "GBP — İngiliz sterlini" },
] as const;

export const BUSINESS_TYPE_OPTIONS = [
  { value: "butik", label: "Butik (tek mağaza)" },
  { value: "coklu_sube", label: "Çok şubeli mağaza" },
  { value: "showroom", label: "Showroom / atölye" },
  { value: "diger", label: "Diğer" },
] as const;

export const APPLICATION_STATUS_LABELS: Record<ApplicationStatus, string> = {
  pending: "İnceleniyor",
  approved: "Onaylandı",
  rejected: "Kabul edilmedi",
  withdrawn: "Geri çekildi",
};

export const SUBSCRIPTION_STATUS_LABELS: Record<SubscriptionStatus, string> = {
  pending: "Ödeme bekliyor",
  active: "Aktif",
  past_due: "Gecikmiş",
  cancelled: "İptal",
  expired: "Süresi doldu",
};

export const BUSINESS_STATUS_LABELS: Record<BusinessStatus, string> = {
  active: "Aktif",
  suspended: "Askıda",
  cancelled: "Kapatıldı",
};

export const INTERVAL_LABELS: Record<BillingInterval, string> = { monthly: "aylık", annual: "yıllık" };

export function formatPlanPrice(plan: { price_amount: number; currency: string; billing_interval: BillingInterval }): string {
  const amount = new Intl.NumberFormat("tr-TR", { style: "currency", currency: plan.currency, maximumFractionDigits: 2 }).format(plan.price_amount);
  return `${amount} / ${plan.billing_interval === "monthly" ? "ay" : "yıl"}`;
}

export function isCountry(v: string): boolean {
  return COUNTRY_OPTIONS.some((o) => o.value === v);
}
export function isCurrency(v: string): boolean {
  return CURRENCY_OPTIONS.some((o) => o.value === v);
}
export function isBusinessType(v: string): boolean {
  return BUSINESS_TYPE_OPTIONS.some((o) => o.value === v);
}

/** Narrows the untrusted signup metadata back into a draft, or null when it is not one. */
export function readApplicationDraft(meta: unknown): ApplicationDraft | null {
  if (!meta || typeof meta !== "object") return null;
  const m = meta as Record<string, unknown>;
  const raw = m.application;
  if (!raw || typeof raw !== "object") return null;
  const d = raw as Record<string, unknown>;
  const business_name = typeof d.business_name === "string" ? d.business_name.trim() : "";
  if (business_name.length < 2) return null;
  const str = (k: string) => (typeof d[k] === "string" && (d[k] as string).trim() !== "" ? (d[k] as string).trim() : null);
  return {
    business_name: business_name.slice(0, 120),
    country: str("country") ?? "TR",
    currency: str("currency") ?? "TRY",
    phone: str("phone"),
    business_type: str("business_type"),
    plan_id: str("plan_id"),
  };
}

/** Shared action-state shapes (a "use server" module may only export async functions). */
export type RegisterState = { error: string | null; done: boolean; email: string | null };
export const REGISTER_IDLE: RegisterState = { error: null, done: false, email: null };
export type ApplyState = { error: string | null };
export const APPLY_IDLE: ApplyState = { error: null };
export type PlatformActionState = { error: string | null; ok: boolean; message?: string };
export const PLATFORM_IDLE: PlatformActionState = { error: null, ok: false };

// ---------------------------------------------------------------- billing (Phase 13B, manual billing only)

export type InvoiceStatus = "open" | "paid" | "void";
export type PaymentMethod = "bank_transfer" | "cash_manual" | "other_manual";

export const INVOICE_STATUS_LABELS: Record<InvoiceStatus, string> = {
  open: "Ödeme bekliyor",
  paid: "Ödendi",
  void: "İptal edildi",
};

export const PAYMENT_METHOD_LABELS: Record<PaymentMethod, string> = {
  bank_transfer: "Havale / EFT",
  cash_manual: "Nakit (elden)",
  other_manual: "Diğer (manuel)",
};

/** The three ways money can arrive in 13B. There is no card, no checkout, no provider. */
export const PAYMENT_METHODS: PaymentMethod[] = ["bank_transfer", "cash_manual", "other_manual"];

/** What the owner and the platform both see of an invoice (fn_saas_invoice_json). */
export type BillingInvoice = {
  id: string;
  invoice_number: string;
  status: InvoiceStatus;
  overdue: boolean;
  days_overdue: number;
  grace_ends_at: string;
  plan_code: string;
  plan_name: string;
  billing_interval: BillingInterval;
  currency: string;
  subtotal: number;
  tax_amount: number;
  tax_policy: "none_unconfigured";
  total: number;
  amount_paid: number;
  balance: number;
  billing_period_start: string;
  billing_period_end: string;
  issued_at: string;
  due_at: string;
  paid_at: string | null;
  voided_at: string | null;
  void_reason: string | null;
  note: string | null;
};

/** What the owner sees of a payment: amount, method, date, reference. No actor, no provider. */
export type BillingPaymentPublic = { amount: number; currency: string; method: PaymentMethod; paid_at: string; reference: string };

export type BillingSubscription = {
  id: string;
  status: SubscriptionStatus;
  starts_at: string | null;
  ends_at: string | null;
  renews_at: string | null;
  activated_at: string | null;
  cancelled_at: string | null;
  cancel_at_period_end: boolean;
  lapsed: boolean;
  plan: { id: string; code: string; name: string; price_amount: number; currency: string; billing_interval: BillingInterval } | null;
};

export type MyBilling = {
  subscription: BillingSubscription | null;
  invoices: Array<BillingInvoice & { payments: BillingPaymentPublic[] }>;
  settings: { billing_grace_days: number };
};

export function formatMoney(amount: number, currency: string): string {
  return new Intl.NumberFormat("tr-TR", { style: "currency", currency, maximumFractionDigits: 2 }).format(amount);
}
