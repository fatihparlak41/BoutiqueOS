import { cn } from "@/lib/utils";

/** Type-only wordmark, set in the editorial serif. */
export function Wordmark({ className }: { className?: string }) {
  return (
    <span className={cn("font-serif font-semibold tracking-tightish text-text-primary", className)}>
      Boutique<span className="italic">OS</span>
    </span>
  );
}
