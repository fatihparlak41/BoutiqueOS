import type { Metadata } from "next";
import { Listing, listingMetadata } from "@/components/shop/listing";

type Search = Record<string, string | string[] | undefined>;

export async function generateMetadata({ params, searchParams }: { params: Promise<{ slug: string }>; searchParams: Promise<Search> }): Promise<Metadata> {
  return listingMetadata(await params, null, await searchParams);
}

export default async function AllProductsPage({ params, searchParams }: { params: Promise<{ slug: string }>; searchParams: Promise<Search> }) {
  const { slug } = await params;
  return <Listing slug={slug} category={null} searchParams={await searchParams} />;
}
