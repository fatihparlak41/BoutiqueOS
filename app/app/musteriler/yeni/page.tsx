import { redirect } from "next/navigation";
import { listSources, loadCrmContext } from "@/lib/crm/queries";
import { CustomerForm } from "@/components/crm/customer-form";

export const metadata = { title: "Yeni müşteri · BoutiqueOS" };

export default async function NewCustomerPage({ searchParams }: { searchParams: Promise<{ geri?: string }> }) {
  const { caps } = await loadCrmContext();
  if (!caps.canAccessCrm) redirect("/app");
  const { geri } = await searchParams;
  const sources = await listSources();
  const redirectTo = geri && geri.startsWith("/app/") ? geri : undefined;
  return (
    <div className="max-w-3xl space-y-6">
      <header>
        <h2 className="font-serif text-xl leading-tight tracking-tightish">Yeni müşteri</h2>
        <p className="mt-1 text-xs text-muted">Kısa tutun: ad, telefon, isteğe bağlı e-posta / Instagram, kaynak ve not. Telefon ya da e-posta zorunlu değildir.</p>
      </header>
      <CustomerForm sources={sources} caps={caps} redirectTo={redirectTo} />
    </div>
  );
}
