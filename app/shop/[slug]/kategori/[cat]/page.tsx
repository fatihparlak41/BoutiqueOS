import type { Metadata } from "next";
import { Listing, listingMetadata } from "@/components/shop/listing";

type Search = Record<string, string | string[] | undefined>;

export async function generateMetadata({ params, searchParams }: { params: Promise<{ slug: string; cat: string }>; searchParams: Promise<Search> }): Promise<Metadata> {
  const { slug, cat } = await params;
  return listingMetadata({ slug }, cat, await searchParams);
}

export default async function CategoryPage({ params, searchParams }: { params: Promise<{ slug: string; cat: string }>; searchParams: Promise<Search> }) {
  const { slug, cat } = await params;
  return <Listing slug={slug} category={cat} searchParams={await searchParams} />;
}
