import Link from "next/link";
import { redirect } from "next/navigation";
import { requireTenant } from "@/lib/tenant";
import { listBranches, listInvites, listTeam, loadTeamContext } from "@/lib/team/queries";
import { PageHeader } from "@/components/ui/page-header";
import { SectionHeader } from "@/components/ui/section-header";
import { EmptyState } from "@/components/ui/empty-state";
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
    <div className="space-y-10">
      <PageHeader
        eyebrow={{ href: "/app/ayarlar", label: "Ayarlar" }}
        title="Ekip"
        description={`${active.business_name} için çalışanları davet edin, rol ve şube atayın, erişimi açıp kapatın.`}
        actions={
          caps.canInvite ? (
            <InviteForm
              branches={branches}
              grantableRoles={caps.grantableRoles}
              maxGrantableDiscount={caps.maxGrantableDiscount}
            />
          ) : undefined
        }
      />

      {openInvites.length > 0 ? (
        <section className="space-y-3">
          <SectionHeader title="Bekleyen davetler" meta={openInvites.length} />
          <InviteList invites={openInvites} />
        </section>
      ) : null}

      <section className="space-y-3">
        <SectionHeader
          title="Üyeler"
          meta={members.length}
          action={
            <Link
              href="/app/ayarlar/ekip/gecmis"
              className="text-text-muted underline-offset-4 hover:text-text-primary hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            >
              Ekip geçmişi
            </Link>
          }
        />

        {members.length === 0 ? (
          <EmptyState compact title="Henüz üye yok" description="Davet ettiğiniz çalışanlar kabul ettiklerinde burada görünür." />
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
          </>
        )}
      </section>
    </div>
  );
}
