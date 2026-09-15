"use client";

import type { StockCount } from "@/lib/stock/count-model";
import { CountingScreen } from "./counting-screen";
import { ReviewScreen } from "./review-screen";
import { ResultScreen } from "./result-screen";

/** One route, one document; the screen follows the document's state. */
export function CountWorkspace({ count, canPost }: { count: StockCount; canPost: boolean }) {
  if (count.status === "draft" || count.status === "counting") return <CountingScreen count={count} canPost={canPost} />;
  if (count.status === "review") return <ReviewScreen count={count} canPost={canPost} />;
  return <ResultScreen count={count} />;
}
