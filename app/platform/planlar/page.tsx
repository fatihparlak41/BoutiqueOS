import { listPlans } from "@/lib/platform/queries";
import { formatPlanPrice, INTERVAL_LABELS } from "@/lib/saas/model";
import { PageHeader } from "@/components/ui/page-header";
import { SectionHeader } from "@/components/ui/section-header";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { PlanForm } from "@/components/platform/forms";

export const metadata = { title: "Planlar · Platform · BoutiqueOS" };

/**
 * The plan catalogue is data. A price lives here and only here; the registration page
 * and the applicant pages render whatever this table says.
 */
export default async function PlansPage({ searchParams }: { searchParams: Promise<{ duzenle?: string }> }) {
  const { duzenle } = await searchParams;
  const plans = await listPlans();
  const editing = duzenle ? (plans.find((p) => p.code === duzenle) ?? null) : null;

  return (
    <div className="space-y-8">
      <PageHeader title="Planlar" description="Kayıt sayfasında sunulan katalog. Fiyat ve dönem buradan değişir; mevcut aboneliklerin kaydı değişmez." />
      <section className="space-y-3">
        <SectionHeader title="Katalog" meta={`${plans.length}`} />
        <TableShell minWidth="40rem">
          <THead>
            <TH>Plan</TH>
            <TH>Dönem</TH>
            <TH align="right">Fiyat</TH>
            <TH align="right">Açık abonelik</TH>
            <TH>Durum</TH>
            <TH />
          </THead>
          <TBody>
            {plans.map((p) => (
              <TR key={p.id}>
                <TD><CellTitle sub={p.code} subNumeric>{p.name}</CellTitle></TD>
                <TD muted>{INTERVAL_LABELS[p.billing_interval]}</TD>
                <TD align="right" numeric>{formatPlanPrice(p)}</TD>
                <TD align="right" numeric>{p.subscriptions}</TD>
                <TD>{p.is_active ? <Badge tone="success">Sunuluyor</Badge> : <Badge tone="neutral">Kapalı</Badge>}</TD>
                <TD align="right">
                  <a href={`/platform/planlar?duzenle=${p.code}`} className="text-xs underline-offset-4 hover:underline">Düzenle</a>
                </TD>
              </TR>
            ))}
          </TBody>
        </TableShell>
      </section>
      <section className="space-y-3">
        <SectionHeader title={editing ? `Düzenle: ${editing.name}` : "Yeni plan"} action={editing ? <a href="/platform/planlar" className="underline-offset-4 hover:underline">Yeni plan</a> : null} />
        <PlanForm key={editing?.code ?? "new"} plan={editing} />
      </section>
    </div>
  );
}
