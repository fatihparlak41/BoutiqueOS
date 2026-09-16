import { notFound, redirect } from "next/navigation";
import { getReservation, loadCrmContext } from "@/lib/crm/queries";
import { ReservationDetail } from "@/components/crm/reservation-detail";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const metadata = { title: "Rezervasyon · BoutiqueOS" };

export default async function ReservationPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  const { caps, branchId } = await loadCrmContext();
  if (!caps.canAccessCrm) redirect("/app");
  const reservation = await getReservation(id);
  if (!reservation) notFound();
  return <ReservationDetail reservation={reservation} canFulfil={reservation.branch_id === branchId} />;
}
