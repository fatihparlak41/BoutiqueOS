import { loadMemberships, ROLE_LABELS } from "@/lib/tenant";
import { selectBusinessAction, signOutAction } from "@/app/auth/actions";
import { Wordmark } from "@/components/brand";
import { Button } from "@/components/ui/button";
import { redirect } from "next/navigation";

export const metadata = { title: "İşletme seçin · BoutiqueOS" };

export default async function SelectBusinessPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const { error } = await searchParams;
  const { memberships } = await loadMemberships();

  if (memberships.length === 0) redirect("/no-access");
  if (memberships.length === 1) redirect("/app");

  return (
    <main className="mx-auto flex min-h-dvh max-w-lg flex-col justify-center px-6 py-16">
      <Wordmark className="text-base" />
      <h1 className="mt-10 text-xl font-medium tracking-tightish">Hangi işletmede çalışacaksınız?</h1>
      <p className="mt-2 text-sm text-muted">Seçiminizi daha sonra üst çubuktan değiştirebilirsiniz.</p>

      {error === "not-a-member" ? (
        <p role="alert" className="mt-6 border-l-2 border-danger bg-panel px-3 py-2 text-sm text-danger">
          Bu işletmede aktif bir üyeliğiniz yok.
        </p>
      ) : null}

      <ul className="mt-8 divide-y divide-line border-y border-line">
        {memberships.map((m) => (
          <li key={m.business_id}>
            <form action={selectBusinessAction}>
              <input type="hidden" name="business_id" value={m.business_id} />
              <button
                type="submit"
                className="flex w-full items-center justify-between gap-4 px-1 py-4 text-left transition-colors hover:bg-panel focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
              >
                <span className="min-w-0">
                  <span className="block truncate font-serif text-base tracking-tightish">
                    {m.business_name}
                  </span>
                  <span className="mt-0.5 block text-xs text-muted">
                    {ROLE_LABELS[m.role]}
                    <span className="mx-1.5 text-line-strong">/</span>
                    {m.branches.length} şube
                  </span>
                </span>
                <span aria-hidden className="text-muted">
                  &rsaquo;
                </span>
              </button>
            </form>
          </li>
        ))}
      </ul>

      <form action={signOutAction} className="mt-8">
        <Button type="submit" variant="ghost" size="sm">
          Çıkış yap
        </Button>
      </form>
    </main>
  );
}
