import { redirect } from "next/navigation";
import { getCustomer, listSources, loadCrmContext } from "@/lib/crm/queries";
import { ReservationForm } from "@/components/crm/reservation-form";

export const metadata = { title: "Yeni rezervasyon · BoutiqueOS" };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function NewReservationPage({ searchParams }: { searchParams: Promise<{ musteri?: string }> }) {
  const { caps, branchId, tenant, supabase, businessId } = await loadCrmContext();
  if (!caps.canAccessCrm) redirect("/app");
  if (!branchId) redirect("/app");
  const { musteri } = await searchParams;
  const [sources, customer] = await Promise.all([listSources(), musteri && UUID.test(musteri) ? getCustomer(musteri) : Promise.resolve(null)]);
  const { data: biz } = await supabase.from("businesses").select("settings").eq("id", businessId).maybeSingle();
  const settings = (biz?.settings ?? {}) as Record<string, unknown>;
  const hours = Number(settings.reservation_default_hours ?? 48) || 48;
  return (
    <div className="max-w-6xl space-y-6">
      <header>
        <h2 className="font-serif text-xl leading-tight tracking-tightish">Yeni rezervasyon</h2>
        <p className="mt-1 text-xs text-muted">{tenant.branch?.name ?? "—"} · müşteri, ürün, adet, süre — ürün stoktan düşmez, yalnız müsait adet azalır.</p>
      </header>
      <ReservationForm branchId={branchId} branchName={tenant.branch?.name ?? "—"} sources={sources} defaultHours={hours}
        initialCustomer={customer ? { id: customer.id, full_name: customer.full_name, phone: customer.phone, email: customer.email, instagram: customer.instagram, source: customer.source, is_active: customer.is_active, order_count: customer.order_count, last_purchase_at: customer.last_purchase_at } : null} />
    </div>
  );
}
