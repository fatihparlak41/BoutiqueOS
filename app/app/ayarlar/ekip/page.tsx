import Link from "next/link";
import { redirect } from "next/navigation";
import { requireTenant } from "@/lib/tenant";
import { listBranches, listInvites, listTeam, loadTeamContext } from "@/lib/team/queries";
import { InviteForm } from "@/components/team/invite-form";
import { InviteList, TeamCards, TeamTable } from "@/components/team/team-rows";

export const metadata = { title: "Ekip · BoutiqueOS" };

export default async function TeamPage() {
  const { active } = await requireTenant();
  const { businessId, caps } = await loadTeamContext();

  // sales_staff and stock_staff have no team management at all. The RPCs refuse them
  // too; this only avoids rendering a page that would be entirely empty.
  if (!caps.canRead) redirect("/app");

  const [members, invites, branches] = await Promise.all([
    listTeam(businessId),
    listInvites(businessId),
    listBranches(businessId),
  ]);

  const openInvites = invites.filter((i) => i.status === "pending" || i.status === "expired");

  return (
    <div className="max-w-5xl space-y-8">
      <header>
        <Link href="/app/ayarlar" className="text-xs text-muted underline-offset-2 hover:underline">
          ← Ayarlar
        </Link>
        <div className="mt-2 flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 className="font-serif text-xl leading-tight tracking-tightish">Ekip</h2>
            <p className="mt-1 text-xs leading-relaxed text-muted">
              {active.business_name} · çalışanları davet edin, rol ve şube atayın, erişimi açıp kapatın.
            </p>
          </div>
          {caps.canInvite ? (
            <InviteForm
              branches={branches}
              grantableRoles={caps.grantableRoles}
              maxGrantableDiscount={caps.maxGrantableDiscount}
            />
          ) : null}
        </div>
      </header>

      {openInvites.length > 0 ? (
        <section className="space-y-3">
          <h3 className="text-sm font-medium tracking-tightish">Bekleyen davetler</h3>
          <InviteList invites={openInvites} />
        </section>
      ) : null}

      <section className="space-y-3">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <h3 className="text-sm font-medium tracking-tightish">Üyeler</h3>
          <Link
            href="/app/ayarlar/ekip/gecmis"
            className="text-xs text-muted underline-offset-2 hover:underline"
          >
            Ekip geçmişi →
          </Link>
        </div>

        {members.length === 0 ? (
          <p className="border border-dashed border-line-strong px-4 py-8 text-center text-xs text-muted">
            Henüz üye yok.
          </p>
        ) : (
          <>
            <TeamTable
              members={members}
              actorRole={active.role}
              branches={branches}
              grantableRoles={caps.grantableRoles}
              maxGrantableDiscount={caps.maxGrantableDiscount}
            />
            <TeamCards
              members={members}
              actorRole={active.role}
              branches={branches}
              grantableRoles={caps.grantableRoles}
              maxGrantableDiscount={caps.maxGrantableDiscount}
            />
            <p className="text-2xs text-muted" data-numeric>
              {members.length} üye listeleniyor.
            </p>
          </>
        )}
      </section>
    </div>
  );
}
