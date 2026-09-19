import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getPublicOrder, getStore } from "@/lib/shop/queries";
import { OrderView } from "@/components/shop/order-view";

export const metadata: Metadata = { title: "Sipariş", robots: { index: false, follow: false, noarchive: true } };
export const dynamic = "force-dynamic";

/**
 * Order tracking by token. The token is the only key: an unknown token is a plain 404,
 * identical to an unknown store, so nothing can be enumerated. Never indexed or cached.
 */
export default async function OrderPage({ params }: { params: Promise<{ slug: string; token: string }> }) {
  const { slug, token } = await params;
  const store = await getStore(slug);
  if (!store) notFound();
  const order = await getPublicOrder(slug, token);
  if (!order) notFound();
  return <OrderView slug={slug} order={order} token={token} />;
}
