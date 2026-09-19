import type { Metadata } from "next";
import { Listing, listingMetadata } from "@/components/shop/listing";

export async function generateMetadata({ params }: { params: Promise<{ slug: string; cat: string }> }): Promise<Metadata> {
  const { slug, cat } = await params;
  return listingMetadata({ slug }, cat);
}

export default async function CategoryPage({ params, searchParams }: { params: Promise<{ slug: string; cat: string }>; searchParams: Promise<{ sirala?: string; sayfa?: string; q?: string }> }) {
  const { slug, cat } = await params;
  return <Listing slug={slug} category={cat} searchParams={await searchParams} />;
}
