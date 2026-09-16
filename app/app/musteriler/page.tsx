import Link from "next/link";
import { redirect } from "next/navigation";
import { listRecentCustomers, listSources, loadCrmContext } from "@/lib/crm/queries";
import { CustomerSearch } from "@/components/crm/customer-search";

export const metadata = { title: "Müşteriler · BoutiqueOS" };

/** Customers: bounded recent list + server search. Owner / manager / sales_staff; stock_staff has no CRM. */
export default async function CustomersPage() {
  const { caps } = await loadCrmContext();
  if (!caps.canAccessCrm) redirect("/app");
  const [recent, sources] = await Promise.all([listRecentCustomers(30), listSources()]);
  return (
    <div className="max-w-3xl space-y-6">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 className="font-serif text-xl leading-tight tracking-tightish">Müşteriler</h2>
          <p className="mt-1 text-xs text-muted">Ad, telefon, e-posta ya da Instagram ile arayın; satış ve rezervasyon geçmişi müşteri sayfasında.</p>
        </div>
        <Link href="/app/musteriler/yeni" className="inline-flex h-11 items-center bg-primary px-4 text-sm text-primary-foreground sm:h-9" data-testid="customer-new">Yeni müşteri</Link>
      </header>
      <CustomerSearch recent={recent} sources={sources} />
    </div>
  );
}
