import { cn } from "@/lib/utils";

/**
 * Colour chip: a small swatch when the value carries a hex, a neutral ring when it does
 * not (Leopar, Çok Renkli, Desenli). The hex is decoration; the label is the identity.
 */
export function ColorSwatch({
  hex,
  label,
  className,
}: {
  hex: string | null;
  label: string;
  className?: string;
}) {
  return (
    <span className={cn("inline-flex items-center gap-1.5", className)}>
      <span
        aria-hidden
        className={cn(
          "inline-block h-3 w-3 shrink-0 rounded-full border",
          hex ? "border-black/10" : "border-dashed border-border-strong bg-transparent",
        )}
        style={hex ? { backgroundColor: hex } : undefined}
      />
      <span>{label}</span>
    </span>
  );
}
