import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getStore } from "@/lib/shop/queries";
import { CartView } from "@/components/shop/cart-view";

export const metadata: Metadata = { title: "Sepet", robots: { index: false } };

export default async function CartPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const store = await getStore(slug);
  if (!store) notFound();
  return <CartView store={store} />;
}
