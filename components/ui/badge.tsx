import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

/**
 * Status chips. Tone is meaning, not decoration:
 *   neutral  — inert / archived / cancelled / inactive
 *   olive    — supportive, in-progress: draft, pending work
 *   accent   — the plum, reserved for "waiting on a person": a pending invitation
 *   success  — posted, active, confirmed
 *   warning  — needs attention: expired, low stock
 *   danger   — damaged, failed, refused
 */
const badgeVariants = cva(
  "inline-flex items-center gap-1 whitespace-nowrap rounded-sm border px-1.5 py-0.5 text-2xs font-medium leading-4",
  {
    variants: {
      tone: {
        neutral: "border-border-strong bg-surface-muted text-text-secondary",
        quiet: "border-border bg-transparent text-text-muted",
        olive: "border-olive/30 bg-olive-muted text-olive",
        accent: "border-accent/25 bg-accent-muted text-accent",
        success: "border-success/25 bg-success-muted text-success",
        warning: "border-warning/30 bg-warning-muted text-warning",
        danger: "border-danger/30 bg-danger-muted text-danger",
      },
    },
    defaultVariants: { tone: "neutral" },
  },
);

export interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement>, VariantProps<typeof badgeVariants> {}

export function Badge({ className, tone, ...props }: BadgeProps) {
  return <span className={cn(badgeVariants({ tone }), className)} {...props} />;
}

export { badgeVariants };
