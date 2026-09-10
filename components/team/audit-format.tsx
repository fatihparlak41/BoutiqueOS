import { AUDIT_ACTION_LABELS } from "@/lib/team/model";

export { AUDIT_ACTION_LABELS };

/**
 * Turkish labels for the roles that can appear inside an audit payload. Kept separate
 * from ROLE_LABELS so an unknown value read out of an old jsonb row degrades to the raw
 * string instead of rendering "undefined".
 */
export const ROLE_LABELS_SAFE: Record<string, string> = {
  owner: "Sahip",
  manager: "Yönetici",
  sales_staff: "Satış",
  stock_staff: "Depo",
};

const FIELD_LABELS: Record<string, string> = {
  role: "Rol",
  branch_id: "Şube",
  max_discount_pct: "İndirim yetkisi",
  is_active: "Durum",
  status: "Davet durumu",
  expires_in_days: "Geçerlilik (gün)",
};

const STATUS_LABELS: Record<string, string> = {
  pending: "Bekliyor",
  accepted: "Kabul edildi",
  revoked: "İptal edildi",
};

export type AuditChange = { field: string; label: string; from: string; to: string };

function render(field: string, value: unknown, roleLabels: Record<string, string>): string {
  if (value === null || value === undefined) return "—";
  if (field === "role") return roleLabels[String(value)] ?? String(value);
  if (field === "is_active") return value === true || value === "true" ? "Aktif" : "Pasif";
  if (field === "status") return STATUS_LABELS[String(value)] ?? String(value);
  if (field === "max_discount_pct") return `%${value}`;
  if (field === "branch_id") return "atandı";
  return String(value);
}

/**
 * Turns one audit row into a readable list of changes.
 *
 * The trigger records EVERY changed whitelist field, so a single statement that moved
 * role, branch, ceiling and active flag together produces four lines here rather than
 * one field and three silently dropped.
 */
export function formatAuditValues(
  oldValues: Record<string, unknown>,
  newValues: Record<string, unknown>,
  roleLabels: Record<string, string>,
): AuditChange[] {
  const fields = Array.from(new Set([...Object.keys(oldValues), ...Object.keys(newValues)]));

  return fields.map((field) => ({
    field,
    label: FIELD_LABELS[field] ?? field,
    from: render(field, oldValues[field], roleLabels),
    to: render(field, newValues[field], roleLabels),
  }));
}
