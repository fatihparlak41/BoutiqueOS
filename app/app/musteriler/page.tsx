import Link from "next/link";
import { redirect } from "next/navigation";
import { listRecentCustomers, listSources, loadCrmContext } from "@/lib/crm/queries";
import { CustomerSearch } from "@/components/crm/customer-search";
import { PageHeader } from "@/components/ui/page-header";
import { Button } from "@/components/ui/button";
import { UserPlus } from "lucide-react";

export const metadata = { title: "Müşteriler · BoutiqueOS" };

/** Customers: bounded recent list + server search. Owner / manager / sales_staff; stock_staff has no CRM. */
export default async function CustomersPage() {
  const { caps } = await loadCrmContext();
  if (!caps.canAccessCrm) redirect("/app");
  const [recent, sources] = await Promise.all([listRecentCustomers(30), listSources()]);
  return (
    <div className="max-w-3xl space-y-6">
      <PageHeader
        title="Müşteriler"
        description="Kim ne aldı, kim ne bekliyor — satış ve rezervasyon geçmişi müşteri sayfasında."
        actions={
          <Link href="/app/musteriler/yeni" data-testid="customer-new">
            <Button variant="accent">
              <UserPlus aria-hidden className="h-4 w-4" />
              Yeni müşteri
            </Button>
          </Link>
        }
      />
      <CustomerSearch recent={recent} sources={sources} />
    </div>
  );
}
