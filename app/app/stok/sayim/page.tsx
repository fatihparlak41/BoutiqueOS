import Link from "next/link";
import { redirect } from "next/navigation";
import { loadAppContext } from "@/lib/app-context";
import { listBranchOptions } from "@/lib/stock/queries";
import { listStockCounts } from "@/lib/stock/count-queries";
import { COUNT_TYPE_LABELS, countCaps, type StockCountListRow } from "@/lib/stock/count-model";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";
import { CreateCountForm } from "@/components/stock/count/create-count-form";
import { StatusBadge, formatWhen } from "@/components/stock/count/shared";

export const metadata = { title: "Stok sayımı · BoutiqueOS" };

/**
 * Counts of this business, newest first, and the form that opens a new one. A count
 * changes stock only when a manager or owner posts it; until then it is a working
 * document. sales_staff has no stock-count role and is sent back to the stock screen.
 */
export default async function StockCountListPage() {
  const { role, branchId } = await loadAppContext();
  if (!countCaps(role).canCount) redirect("/app/stok");

  const [counts, branches] = await Promise.all([listStockCounts(), listBranchOptions()]);
  const open = counts.filter((c) => c.status === "draft" || c.status === "counting" || c.status === "review");
  const closed = counts.filter((c) => c.status === "posted" || c.status === "cancelled");

  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow={{ href: "/app/stok", label: "Stok" }}
        title="Stok sayımı"
        description="Rafı sayın, farkları inceleyin, işleyin. Sayım işlenene kadar stok değişmez; işlenen sayım değiştirilemez."
      />

      <section className="space-y-3">
        <h2 className="text-sm font-medium">Yeni sayım</h2>
        <CreateCountForm branches={branches} defaultBranchId={branchId} />
      </section>

      <section className="space-y-3">
        <h2 className="text-sm font-medium">
          Açık sayımlar <span className="ml-1 text-xs font-normal text-text-muted" data-numeric>{open.length}</span>
        </h2>
        {open.length === 0 ? <p className="text-sm text-text-muted">Açık sayım yok.</p> : <CountList rows={open} />}
      </section>

      <section className="space-y-3">
        <h2 className="text-sm font-medium">
          Geçmiş <span className="ml-1 text-xs font-normal text-text-muted" data-numeric>{closed.length}</span>
        </h2>
        {closed.length === 0 ? (
          <EmptyState compact title="Henüz işlenmiş sayım yok" description="İlk sayımı başlatın; işlendiğinde burada kalıcı olarak görünür." />
        ) : (
          <CountList rows={closed} />
        )}
      </section>
    </div>
  );
}

function CountList({ rows }: { rows: StockCountListRow[] }) {
  return (
    <ul className="divide-y divide-border border-y border-border">
      {rows.map((c) => (
        <li key={c.id}>
          <Link href={`/app/stok/sayim/${c.id}`} className="flex min-h-14 items-center justify-between gap-3 py-2.5 hover:bg-surface-muted/60">
            <div className="min-w-0">
              <p className="flex flex-wrap items-center gap-2 text-sm font-medium">
                <span data-numeric>{c.count_number}</span>
                <StatusBadge status={c.status} />
              </p>
              <p className="text-2xs text-text-muted">
                {COUNT_TYPE_LABELS[c.count_type]} · {c.branch_name} · {c.created_by_name ?? "—"} · <span data-numeric>{formatWhen(c.created_at)}</span>
                {c.note ? ` · ${c.note}` : ""}
              </p>
            </div>
            <span className="shrink-0 text-xs text-text-secondary" data-numeric>
              {c.counted_lines}/{c.line_count} satır
            </span>
          </Link>
        </li>
      ))}
    </ul>
  );
}
