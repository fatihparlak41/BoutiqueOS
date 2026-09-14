import * as React from "react";
import { cn } from "@/lib/utils";

/**
 * A card is a real object or state — a business to pick, a member on a phone, a stock
 * variant on a phone. It is not a layout device: sections are separated by space and
 * hairlines, never by nesting cards in cards.
 */
export function Card({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("rounded border border-border bg-surface", className)} {...props} />;
}

export function CardBody({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("p-4", className)} {...props} />;
}
