import { redirect } from "next/navigation";
import { loadMemberships } from "@/lib/tenant";
import { signOutAction } from "@/app/auth/actions";
import { Wordmark } from "@/components/brand";
import { Button } from "@/components/ui/button";
import { BusinessPicker } from "./business-picker";

export const metadata = { title: "İşletme seçin · BoutiqueOS" };

/**
 * Tenant chooser for an account that belongs to more than one business.
 *
 * The list is rendered by a client component on purpose. This page previously had no
 * client component anywhere in its tree, so React never hydrated it and the server
 * action forms stayed parked on their pre-hydration guard — the buttons produced no
 * request at all. That also silently disabled "Çıkış yap" below.
 */
export default async function SelectBusinessPage() {
  const { memberships } = await loadMemberships();

  if (memberships.length === 0) redirect("/no-access");
  if (memberships.length === 1) redirect("/app");

  return (
    <main className="mx-auto flex min-h-dvh max-w-lg flex-col justify-center px-6 py-16">
      <Wordmark className="text-base" />
      <h1 className="mt-10 text-xl font-medium tracking-tightish">Hangi işletmede çalışacaksınız?</h1>
      <p className="mt-2 text-sm text-muted">Seçiminizi daha sonra üst çubuktan değiştirebilirsiniz.</p>

      <BusinessPicker
        options={memberships.map((m) => ({
          business_id: m.business_id,
          business_name: m.business_name,
          role: m.role,
          branch_count: m.branches.length,
        }))}
      />

      <form action={signOutAction} className="mt-8">
        <Button type="submit" variant="ghost" size="sm">
          Çıkış yap
        </Button>
      </form>
    </main>
  );
}
