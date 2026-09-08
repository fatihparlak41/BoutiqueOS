import { cn } from "@/lib/utils";

/** Type-only wordmark. The serif appears here and on the tenant name — nowhere else. */
export function Wordmark({ className }: { className?: string }) {
  return (
    <span className={cn("font-serif tracking-tightish", className)}>
      Boutique<span className="italic">OS</span>
    </span>
  );
}
