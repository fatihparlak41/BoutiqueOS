import Link from "next/link";
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
 * Suspended and cancelled businesses never reach this list: loadMemberships keeps only
 * active ones. The list is rendered by a client component so the server-action forms
 * hydrate (the page once had no client component and its buttons produced no request).
 */
export default async function SelectBusinessPage() {
  const { memberships, user, profile } = await loadMemberships();

  if (memberships.length === 0) redirect("/no-access");
  if (memberships.length === 1) redirect("/app");

  const who = profile.full_name?.trim() || user.email || "";

  return (
    <main className="min-h-dvh bg-background">
      <div className="mx-auto flex min-h-dvh w-full max-w-xl flex-col px-6 py-10 sm:px-8 sm:py-14">
        <div className="flex items-center justify-between gap-4">
          <Wordmark className="text-lg" />
          <form action={signOutAction}>
            <Button type="submit" variant="ghost" size="sm">
              Çıkış yap
            </Button>
          </form>
        </div>

        <div className="mt-14 sm:mt-20">
          <p className="text-sm text-text-muted">{who}</p>
          <h1 className="mt-2 font-serif text-4xl font-medium leading-none tracking-tightish text-text-primary">
            Hangi işletmede çalışacaksınız?
          </h1>
          <p className="mt-3 max-w-prose text-sm leading-relaxed text-text-muted">
            Bu hesap {memberships.length} işletmeye üye. Seçiminizi daha sonra kenar çubuğundaki işletme
            plakasından değiştirebilirsiniz.
          </p>
        </div>

        <div className="mt-8">
          <BusinessPicker
            options={memberships.map((m) => ({
              business_id: m.business_id,
              business_name: m.business_name,
              business_code: m.business_code,
              role: m.role,
              branch_count: m.branches.length,
            }))}
          />
          <p className="mt-6 text-xs text-text-muted">
            Başka bir işletme mi açacaksınız?{" "}
            <Link href="/basvuru" className="underline-offset-4 hover:text-text-primary hover:underline">
              Yeni işletme başvurusu
            </Link>
          </p>
        </div>
      </div>
    </main>
  );
}
