import { redirect } from "next/navigation";
import { listMembers, listRegisters, loadPosContext } from "@/lib/pos/queries";
import { ReturnsTerminal } from "@/components/pos/returns-terminal";

export const metadata = { title: "İade / Değişim · BoutiqueOS" };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * İade / değişim. Any selling role may look a sale up and prepare the case; completing
 * a refund or an exchange is owner/manager (the RPCs refuse everyone else). A cash refund
 * or an exchange needs the branch's open drawer — opened by a manager (Phase 9A).
 */
export default async function ReturnsPage({ searchParams }: { searchParams: Promise<{ satis?: string }> }) {
  const [{ caps, branchId, tenant }, registers, members, { satis }] = await Promise.all([loadPosContext(), listRegisters(), listMembers(), searchParams]);
  if (!caps.canSell) redirect("/app");
  if (!branchId) redirect("/app");
  const anyOpen = registers.some((r) => r.open_session);

  return (
    <div className="max-w-6xl space-y-6">
      <header>
        <h2 className="font-serif text-xl leading-tight tracking-tightish">İade / Değişim</h2>
        <p className="mt-1 text-xs text-muted">
          {tenant.branch?.name ?? "—"} · satışı bulun, geri gelen ürünleri seçin, politikaya göre değişim ya da iade yapın.
          {!anyOpen ? " Açık kasa oturumu yok — değişim ve nakit iade için yönetici kasayı açmalı." : ""}
        </p>
      </header>
      <ReturnsTerminal registers={registers} members={members} caps={caps} initialSaleId={satis && UUID.test(satis) ? satis : undefined} />
    </div>
  );
}
