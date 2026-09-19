import Link from "next/link";
import { BookmarkCheck } from "lucide-react";
import { EmptyState } from "@/components/ui/empty-state";
import { Button } from "@/components/ui/button";
import { redirect } from "next/navigation";
import { listReservations, loadCrmContext } from "@/lib/crm/queries";
import { RESERVATION_STATUS_LABELS } from "@/lib/crm/model";
import { formatDateTime } from "@/lib/receiving/format";
import { cn } from "@/lib/utils";

export const metadata = { title: "Rezervasyonlar · BoutiqueOS" };

/** Active holds first (soonest expiry on top), history behind a tab. Past-due active rows are flagged: they no longer hold stock. */
export default async function ReservationsPage({ searchParams }: { searchParams: Promise<{ durum?: string }> }) {
  const { caps } = await loadCrmContext();
  if (!caps.canAccessCrm) redirect("/app");
  const { durum } = await searchParams;
  const history = durum === "gecmis";
  const rows = await listReservations(history ? "history" : "active");
  return (
    <div className="max-w-3xl space-y-6">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 className="font-serif text-xl leading-tight tracking-tightish">Rezervasyonlar</h2>
          <p className="mt-1 text-xs text-muted">Ayrılan ürün stoktan düşmez; yalnız müsait adedi azaltır. Süresi geçen rezervasyon stoğu otomatik bırakır.</p>
        </div>
        <Link href="/app/rezervasyonlar/yeni" className="inline-flex h-11 items-center bg-primary px-4 text-sm text-primary-foreground sm:h-9" data-testid="rsv-new">Yeni rezervasyon</Link>
      </header>
      <div className="grid grid-cols-2 border border-line text-xs" role="tablist">
        <Link href="/app/rezervasyonlar" role="tab" aria-selected={!history} className={cn("flex h-10 items-center justify-center border-r border-line", !history ? "bg-primary text-primary-foreground" : "text-ink-70")}>Aktif</Link>
        <Link href="/app/rezervasyonlar?durum=gecmis" role="tab" aria-selected={history} className={cn("flex h-10 items-center justify-center", history ? "bg-primary text-primary-foreground" : "text-ink-70")}>Geçmiş</Link>
      </div>
      {rows.length === 0 ? (
        history ? (
          <EmptyState compact title="Geçmiş rezervasyon yok" description="Teslim edilen, iptal edilen ve süresi dolan ayırmalar burada birikir." />
        ) : (
          <EmptyState icon={<BookmarkCheck />} title="Aktif rezervasyon yok" description="Instagram ya da WhatsApp'tan gelen istekleri burada ayır; stok satılmadan müşteriyi bekler." action={<Link href="/app/rezervasyonlar/yeni"><Button variant="outline">Rezervasyon yap</Button></Link>} />
        )
      ) : (
        <ul className="divide-y divide-line border-y border-line" data-testid="rsv-list">
          {rows.map((r) => (
            <li key={r.id}>
              <Link href={`/app/rezervasyonlar/${r.id}`} className="flex items-center gap-3 px-1 py-3 hover:bg-panel">
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium text-ink" data-numeric>{r.reservation_number} <span className="font-normal text-muted">· {r.customer?.full_name ?? "—"}</span></p>
                  <p className="truncate text-2xs text-muted" data-numeric>{r.items.map((i) => `${i.quantity}× ${i.variant.product_name}${i.variant.options ? ` (${i.variant.options})` : ""}`).join(", ")}</p>
                </div>
                <div className="text-right text-2xs" data-numeric>
                  <p className={cn(r.is_past_due ? "text-danger" : r.status === "active" ? "text-success" : "text-muted")}>{r.is_past_due ? "Süresi geçti" : RESERVATION_STATUS_LABELS[r.status]}</p>
                  <p className="text-muted">{formatDateTime(r.expires_at)}</p>
                </div>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
