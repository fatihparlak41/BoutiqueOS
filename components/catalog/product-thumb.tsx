import { ImageOff } from "lucide-react";
import { cn } from "@/lib/utils";

/**
 * Small operational thumbnail. A plain <img> on purpose: the source is a short-lived
 * signed URL from a private bucket, so next/image's optimisation cache would be wrong
 * for it. Missing images get a quiet placeholder, never a broken icon.
 */
export function ProductThumb({
  url,
  alt,
  size = "sm",
  className,
}: {
  url: string | null;
  alt: string;
  size?: "sm" | "md" | "lg";
  className?: string;
}) {
  const box = size === "lg" ? "h-32 w-32 sm:h-40 sm:w-40" : size === "md" ? "h-16 w-16" : "h-10 w-10";
  return (
    <span
      className={cn(
        "flex shrink-0 items-center justify-center overflow-hidden rounded border border-border bg-surface-muted/60",
        box,
        className,
      )}
    >
      {url ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={url} alt={alt} className="h-full w-full object-cover" loading="lazy" />
      ) : (
        <ImageOff aria-hidden className="h-4 w-4 stroke-[1.5] text-text-muted/60" />
      )}
    </span>
  );
}
