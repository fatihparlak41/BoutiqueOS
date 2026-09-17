"use client";

import { RouteError } from "@/components/ui/route-states";

export default function Error({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return <RouteError title="Raporlar" error={error} reset={reset} />;
}
