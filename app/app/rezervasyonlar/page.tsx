import Link from "next/link";
import { BookmarkCheck } from "lucide-react";
import { EmptyState } from "@/components/ui/empty-state";
import { Button } from "@/components/ui/button";
import { PageHeader } from "@/components/ui/page-header";
import { Badge } from "@/components/ui/badge";
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
      <PageHeader
        title="Rezervasyonlar"
        description="Müşteri için ayrılan ürün satılabilir sayılmaz; süresi dolunca kendiliğinden serbest kalır."
        actions={
          <Link href="/app/rezervasyonlar/yeni" data-testid="rsv-new">
            <Button variant="accent">Yeni rezervasyon</Button>
          </Link>
        }
      />
      <div className="grid grid-cols-2 border border-line text-xs" role="tablist">
        <Link href="/app/rezervasyonlar" role="tab" aria-selected={!history} className={cn("flex h-10 items-center justify-center border-r border-line", !history ? "bg-accent text-accent-foreground" : "text-ink-70")}>Aktif</Link>
        <Link href="/app/rezervasyonlar?durum=gecmis" role="tab" aria-selected={history} className={cn("flex h-10 items-center justify-center", history ? "bg-accent text-accent-foreground" : "text-ink-70")}>Geçmiş</Link>
      </div>
      {rows.length === 0 ? (
        history ? (
          <EmptyState compact title="Geçmiş rezervasyon yok" description="Tamamlanan, iptal edilen ve süresi dolan rezervasyonlar burada birikir." />
        ) : (
          <EmptyState editorial icon={<BookmarkCheck />} title="Bekleyen rezervasyon yok" description="Instagram ya da WhatsApp'tan gelen istekleri burada ayır; ürün satılmadan müşteriyi bekler, kasada tek dokunuşla teslim edilir." action={<Link href="/app/rezervasyonlar/yeni"><Button variant="outline">Yeni rezervasyon</Button></Link>} />
        )
      ) : (
        <ul className="divide-y divide-line border-y border-line" data-testid="rsv-list">
          {rows.map((r) => (
            <li key={r.id}>
              <Link href={`/app/rezervasyonlar/${r.id}`} className="flex min-h-14 items-center gap-3 px-1 py-3 hover:bg-panel">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-ink">{r.customer?.full_name ?? "—"} <span className="font-normal text-muted" data-numeric>· {r.reservation_number}</span></p>
                  <p className="truncate text-xs text-muted" data-numeric>{r.items.map((i) => `${i.quantity}× ${i.variant.product_name}${i.variant.options ? ` (${i.variant.options})` : ""}`).join(", ")}</p>
                </div>
                <div className="shrink-0 text-right text-2xs" data-numeric>
                  <ReservationStatus status={r.status} pastDue={r.is_past_due} />
                  <p className={cn("mt-1", r.status === "active" && !r.is_past_due ? "text-ink-70" : "text-muted")}>{r.status === "active" && !r.is_past_due ? "son gün " : ""}{formatDateTime(r.expires_at)}</p>
                </div>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/** Plain status words: Aktif / Süresi doldu / Tamamlandı / İptal edildi. An active hold past its time no longer holds stock, so it reads as expired. */
function ReservationStatus({ status, pastDue }: { status: keyof typeof RESERVATION_STATUS_LABELS; pastDue: boolean }) {
  const expired = pastDue || status === "expired";
  const tone = expired ? "warning" : status === "active" ? "success" : status === "converted" ? "neutral" : "quiet";
  return <Badge tone={tone}>{expired ? "Süresi doldu" : RESERVATION_STATUS_LABELS[status]}</Badge>;
}
