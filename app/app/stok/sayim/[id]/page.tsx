import { notFound, redirect } from "next/navigation";
import { loadAppContext } from "@/lib/app-context";
import { getStockCount } from "@/lib/stock/count-queries";
import { COUNT_TYPE_LABELS, countCaps } from "@/lib/stock/count-model";
import { PageHeader } from "@/components/ui/page-header";
import { CountWorkspace } from "@/components/stock/count/count-workspace";
import { StatusBadge } from "@/components/stock/count/shared";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const metadata = { title: "Sayım · BoutiqueOS" };

export default async function StockCountPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  const { role } = await loadAppContext();
  if (!countCaps(role).canCount) redirect("/app/stok");

  // RLS scopes the read to the tenant: another business's count reads as missing.
  const count = await getStockCount(id);
  if (!count) notFound();

  return (
    <div className="mx-auto max-w-3xl space-y-5">
      <PageHeader
        eyebrow={{ href: "/app/stok/sayim", label: "Stok sayımı" }}
        title={
          <span className="flex flex-wrap items-center gap-2">
            <span data-numeric>{count.count_number}</span>
            <StatusBadge status={count.status} />
          </span>
        }
        description={`${COUNT_TYPE_LABELS[count.count_type]} · ${count.branch_name}${count.note ? ` · ${count.note}` : ""}`}
      />
      <CountWorkspace count={count} canPost={countCaps(role).canPost} />
    </div>
  );
}
