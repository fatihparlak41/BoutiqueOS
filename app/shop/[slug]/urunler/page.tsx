import type { Metadata } from "next";
import { Listing, listingMetadata } from "@/components/shop/listing";

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  return listingMetadata(await params, null);
}

export default async function AllProductsPage({ params, searchParams }: { params: Promise<{ slug: string }>; searchParams: Promise<{ sirala?: string; sayfa?: string; q?: string }> }) {
  const { slug } = await params;
  return <Listing slug={slug} category={null} searchParams={await searchParams} />;
}
