import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getStore } from "@/lib/shop/queries";
import { CheckoutView } from "@/components/shop/checkout-view";

export const metadata: Metadata = { title: "Sipariş talebi", robots: { index: false, follow: false } };

/** Guest checkout — an order request with a hold, never a payment. Not indexed. */
export default async function CheckoutPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const store = await getStore(slug);
  if (!store) notFound();
  return <CheckoutView store={store} />;
}
