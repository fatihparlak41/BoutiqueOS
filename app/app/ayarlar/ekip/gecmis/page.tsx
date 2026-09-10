import Link from "next/link";
import { redirect } from "next/navigation";
import { listTeamAudit, loadTeamContext } from "@/lib/team/queries";
import { AUDIT_ACTION_LABELS, ROLE_LABELS_SAFE, formatAuditValues } from "@/components/team/audit-format";

export const metadata = { title: "Ekip geçmişi · BoutiqueOS" };

function formatMoment(value: string): string {
  return new Date(value).toLocaleString("tr-TR", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export default async function TeamHistoryPage() {
  const { businessId, caps } = await loadTeamContext();
  if (!caps.canRead) redirect("/app");

  const entries = await listTeamAudit(businessId);

  return (
    <div className="max-w-4xl space-y-8">
      <header>
        <Link href="/app/ayarlar/ekip" className="text-xs text-muted underline-offset-2 hover:underline">
          ← Ekip
        </Link>
        <h2 className="mt-2 font-serif text-xl leading-tight tracking-tightish">Ekip geçmişi</h2>
        <p className="mt-1 text-xs leading-relaxed text-muted">
          Rol, şube, indirim yetkisi ve erişim değişiklikleri ile davet hareketleri. Parola değerleri
          hiçbir zaman kaydedilmez.
        </p>
      </header>

      {entries.length === 0 ? (
        <p className="border border-dashed border-line-strong px-4 py-8 text-center text-xs text-muted">
          Henüz kayıt yok.
        </p>
      ) : (
        <ul className="divide-y divide-line border-y border-line">
          {entries.map((entry) => {
            const changes = formatAuditValues(entry.old_values, entry.new_values, ROLE_LABELS_SAFE);
            return (
              <li key={entry.id} className="py-3">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="text-sm font-medium">{AUDIT_ACTION_LABELS[entry.action]}</span>
                  <span className="text-2xs text-muted" data-numeric>
                    {formatMoment(entry.occurred_at)}
                  </span>
                </div>
                <p className="mt-0.5 text-2xs text-muted">
                  {entry.target_name ?? entry.target_invite_email ?? "—"}
                  <span aria-hidden> · </span>
                  {entry.actor_name ? `${entry.actor_name} tarafından` : "sistem"}
                </p>
                {changes.length > 0 ? (
                  <ul className="mt-2 space-y-0.5">
                    {changes.map((change) => (
                      <li key={change.field} className="text-2xs text-ink-70">
                        <span className="text-muted">{change.label}:</span> {change.from} → {change.to}
                      </li>
                    ))}
                  </ul>
                ) : null}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
