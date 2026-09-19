import { Badge } from "@/components/ui/badge";
import {
  APPLICATION_STATUS_LABELS,
  BUSINESS_STATUS_LABELS,
  INVOICE_STATUS_LABELS,
  SUBSCRIPTION_STATUS_LABELS,
  type ApplicationStatus,
  type BusinessStatus,
  type InvoiceStatus,
  type SubscriptionStatus,
} from "@/lib/saas/model";

export function ApplicationPill({ status }: { status: ApplicationStatus }) {
  const tone = status === "pending" ? "accent" : status === "approved" ? "success" : status === "rejected" ? "danger" : "neutral";
  return <Badge tone={tone}>{APPLICATION_STATUS_LABELS[status]}</Badge>;
}

export function BusinessPill({ status }: { status: BusinessStatus }) {
  const tone = status === "active" ? "success" : status === "suspended" ? "warning" : "neutral";
  return <Badge tone={tone}>{BUSINESS_STATUS_LABELS[status]}</Badge>;
}

/** Overdue is a derived fact (open + past due), shown as a warning without a fourth stored state. */
export function InvoicePill({ status, overdue }: { status: InvoiceStatus; overdue?: boolean }) {
  if (status === "open" && overdue) return <Badge tone="warning">Vadesi geçti</Badge>;
  const tone = status === "paid" ? "success" : status === "open" ? "accent" : "neutral";
  return <Badge tone={tone}>{INVOICE_STATUS_LABELS[status]}</Badge>;
}

export function SubscriptionPill({ status }: { status: SubscriptionStatus }) {
  const tone = status === "active" ? "success" : status === "pending" ? "accent" : status === "past_due" ? "warning" : "neutral";
  return <Badge tone={tone}>{SUBSCRIPTION_STATUS_LABELS[status]}</Badge>;
}

const dateTime = new Intl.DateTimeFormat("tr-TR", { dateStyle: "medium", timeStyle: "short" });
const dateOnly = new Intl.DateTimeFormat("tr-TR", { dateStyle: "medium" });

export function fmtDateTime(iso: string | null | undefined): string {
  return iso ? dateTime.format(new Date(iso)) : "—";
}
export function fmtDate(iso: string | null | undefined): string {
  return iso ? dateOnly.format(new Date(iso)) : "—";
}
