import { getIntelHome, loadIntelContext, parseDays, parseThresholds, resolveBranch } from "@/lib/intel/queries";
import { IntelPage, WindowBar, IntelDefinitions } from "@/components/intel/intel-shell";
import { Section, VariantRows, FastMoverRows, BrokenRows, ReturnRows, HoldRows } from "@/components/intel/signal-list";
import { Kpi, KpiStrip } from "@/components/reports/kpi";
import { fmtInt, fmtMoney } from "@/components/reports/format";
import { EmptyState } from "@/components/ui/empty-state";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";

export const metadata = { title: "Analiz · BoutiqueOS" };

type Params = Record<string, string | undefined>;

/**
 * Intelligence home: one aggregate RPC, seven short lists. Every row shows the numbers
 * that put it there. With too little data the page says so instead of ranking noise.
 */
export default async function IntelHomePage({ searchParams }: { searchParams: Promise<Params> }) {
  const params = await searchParams;
  const ctx = await loadIntelContext();
  const days = parseDays(params.gun);
  const thresholds = parseThresholds(params);
  // no branch filter → the branch list and the aggregate run in the same round trip
  const branchP = resolveBranch(params.sube);
  const [{ branchId, branches }, home] = await Promise.all([
    branchP,
    params.sube ? branchP.then((b) => getIntelHome(b.branchId, days, thresholds)) : getIntelHome(null, days, thresholds),
  ]);
  const s = home.summary;
  const fin = home.financial;
  const query = `?gun=${days}${branchId ? `&sube=${branchId}` : ""}`;
  const sparse = home.sales && !s.enough_data;

  return (
    <IntelPage title="Sinyaller" description="Kurala dayalı, açıklanabilir sinyaller: her satır kendisini listeye sokan sayıları taşır. Tahmin yok, puan yok." current="/app/analiz" caps={ctx.caps} query={query}>
      <WindowBar basePath="/app/analiz" window={home.window} days={days} branches={branches} branchId={branchId} thresholds={home.thresholds} />
      {home.scope !== "business" ? <p className="text-xs text-text-muted">Satışa dayalı sinyaller yalnız görebildiğiniz satışları kapsar.</p> : null}

      <KpiStrip>
        <Kpi label="Aktif varyant" value={fmtInt(s.variants)} hint={`${fmtInt(s.products)} ürün · ${fmtInt(s.with_stock)} stoklu`} />
        <Kpi label="Tükenen" value={fmtInt(s.out_of_stock)} hint={s.never_stocked > 0 ? `${fmtInt(s.never_stocked)} hiç stoklanmadı` : "arz edilmiş, müsaidi kalmamış"} />
        {home.sales ? <Kpi label="Dönemde satılan" value={fmtInt(s.sold_win)} hint={`${fmtInt(s.sales_win)} işlem · ${fmtInt(s.returned_win)} iade`} /> : null}
        {home.reservation_demand !== null ? <Kpi label="Aktif rezervasyon" value={fmtInt(s.holds_active)} /> : null}
      </KpiStrip>

      {sparse ? (
        <EmptyState
          title="Henüz yeterli veri yok"
          description={`Dönemde ${fmtInt(s.sold_win)} adet satıldı; satışa dayalı sinyaller için en az ${fmtInt(home.thresholds.min_sample)} adet gerekir. Stok tarafındaki sinyaller (bedeni kırılan ürünler, tükenenler, yaşlanan stok) yine aşağıda.`}
        />
      ) : null}

      {home.sales && !sparse ? (
        <Section title="Hızlı satanlar" empty="Dönemde en az 3 adet satmış ve 7 gündür raftaki ürün yok." hint="Satış hızına göre: dönemde satılan adet ÷ aktif gün. Ömür boyu toplam adet tek başına sıralamaz." count={home.fast_movers?.length ?? 0}>
          <FastMoverRows rows={home.fast_movers ?? []} />
        </Section>
      ) : null}

      {home.sales ? (
        <Section title="Yeniden sipariş adayları" empty="Satış hızına göre stoku azalan varyant yok." hint="Sipariş kendiliğinden oluşmaz: bağlantı yalnız bir taslağı açar, adedi siz girersiniz. Tedarik süresi kayıtlı olmadığından tahmin edilmez." count={home.replenishment?.length ?? 0}>
          <VariantRows rows={home.replenishment ?? []} financial={false} orderLink={home.financial} numbers={(r) => `${fmtInt(r.sold_win)} satış · ${fmtInt(r.available)} müsait${r.days_of_cover !== null && r.days_of_cover !== undefined ? ` · ${fmtInt(r.days_of_cover)} günlük` : ""}`} />
        </Section>
      ) : null}

      <Section title="Bedeni kırılan ürünler" empty="Bedenli ürünlerde eksik beden yok." hint="Bazı bedenler müsaitken daha önce arz edilmiş bir beden tükenmiş. Yeniden sipariş kararı sizin." count={home.broken_size_runs.length}>
        <BrokenRows rows={home.broken_size_runs} />
      </Section>

      <Section title="Stokta biten varyantlar" empty="Talebi olup tükenen varyant yok." hint={home.sales ? "Arz edilmiş, şu an müsaidi olmayan; dönemde satışı ya da bekleyen rezervasyonu olanlar." : "Arz edilmiş, şu an satılabilir adedi kalmayan varyantlar."} count={home.out_of_stock.length}>
        <VariantRows rows={home.out_of_stock} financial={false} numbers={(r) => `${home.sales ? `${fmtInt(r.sold_win)} satış` : ""}${r.holds_active ? ` · ${fmtInt(r.holds_active)} rezervasyon` : ""}`} />
      </Section>

      {home.sales ? (
        <Section title="Yavaş hareket edenler" empty="Eşiklere göre yavaş hareket eden varyant yok (yeni gelen ürün yavaş sayılmaz)." count={home.slow_movers?.length ?? 0}>
          <VariantRows rows={home.slow_movers ?? []} financial={fin} numbers={(r) => `${fmtInt(r.available)} müsait · ${fmtInt(r.age_days ?? 0)} gün`} />
        </Section>
      ) : null}

      {home.sales ? (
        <Section title="Fazla stok adayları" empty="Müsait adedi satış hızına göre fazla olan varyant yok." hint="İndirim önerilmez; yalnız stok derinliği ile hız karşılaştırılır." count={home.excess?.length ?? 0}>
          <VariantRows rows={home.excess ?? []} financial={fin} numbers={(r) => `${fmtInt(r.available)} müsait · ${fmtInt(r.age_days ?? 0)} gün`} />
        </Section>
      ) : null}

      <Section title="Yaşlanan stok" empty="Satılabilir stok yok." hint="İlk satılabilir giriş tarihine göre; yeniden alım yaşı sıfırlamaz." count={home.aging.reduce((n, b) => n + b.units, 0)} meta={`${fmtInt(home.aging.reduce((n, b) => n + b.units, 0))} adet`}>
        <TableShell minWidth={fin ? "30rem" : "22rem"}>
          <THead>
            <TH>Yaş (gün)</TH>
            <TH align="right">Adet</TH>
            <TH align="right">Varyant</TH>
            <TH align="right">30+ gündür satışsız</TH>
            {fin ? <TH align="right">Stok değeri</TH> : null}
          </THead>
          <TBody>
            {home.aging.map((b) => (
              <TR key={b.bucket}>
                <TD nowrap>{b.bucket}</TD>
                <TD align="right" numeric>{fmtInt(b.units)}</TD>
                <TD align="right" numeric muted>{fmtInt(b.variants)}</TD>
                <TD align="right" numeric muted>{fmtInt(b.no_sale_units)}</TD>
                {fin ? <TD align="right" numeric>{fmtMoney(b.value)}</TD> : null}
              </TR>
            ))}
          </TBody>
        </TableShell>
      </Section>

      {home.sales ? (
        <Section title="İade sinyalleri" empty="Dönemde iade yok." hint={`Yüzde yalnız ${fmtInt(home.thresholds.min_sample)} ve üzeri satışta gösterilir; altı "küçük örneklem" olarak kalır.`} count={home.return_signals?.length ?? 0}>
          <ReturnRows rows={home.return_signals ?? []} minSample={home.thresholds.min_sample} />
        </Section>
      ) : null}

      {home.reservation_demand !== null ? (
        <Section title="Rezervasyon talebi" empty="Dönemde rezervasyon hareketi yok." hint="Süresi dolan ya da iptal edilen rezervasyon satış talebi sayılmaz; ayrı gösterilir." count={home.reservation_demand.length}>
          <HoldRows rows={home.reservation_demand} />
        </Section>
      ) : null}

      <IntelDefinitions financial={fin} />
    </IntelPage>
  );
}
