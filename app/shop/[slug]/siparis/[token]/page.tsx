import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getPublicOrder, getStore } from "@/lib/shop/queries";
import { OrderView } from "@/components/shop/order-view";

export const metadata: Metadata = { title: "Sipariş", robots: { index: false, follow: false, noarchive: true } };
export const dynamic = "force-dynamic";

/**
 * Order success (?yeni=1, right after the request) and tracking, by token. The token is the
 * only key: an unknown token is the store's own 404, identical to any missing page, so
 * nothing can be enumerated. Never indexed or cached; the token is never logged.
 */
export default async function OrderPage({ params, searchParams }: { params: Promise<{ slug: string; token: string }>; searchParams: Promise<{ yeni?: string }> }) {
  const { slug, token } = await params;
  const { yeni } = await searchParams;
  const store = await getStore(slug);
  if (!store) notFound();
  const order = await getPublicOrder(slug, token);
  if (!order) notFound();
  return <OrderView slug={slug} order={order} token={token} justCreated={yeni === "1"} />;
}
