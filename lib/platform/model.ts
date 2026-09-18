import type { ApplicationStatus, BillingInterval, BusinessStatus, SubscriptionStatus } from "@/lib/saas/model";

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
  activated_at: string | null;
  cancelled_at: string | null;
  source: string;
  note: string | null;
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
};

export function pageOffset(page: string | undefined): number {
  const n = Number.parseInt(page ?? "1", 10);
  return Number.isFinite(n) && n > 1 ? (n - 1) * PAGE_SIZE : 0;
}
