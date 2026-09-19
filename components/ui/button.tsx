import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

/**
 * Two action colours: charcoal for ordinary actions, plum (`accent`) for the one
 * primary action of a screen — "Ürün ekle", "Ürünü kaydet". Plum stays rare enough to
 * mean "this is the thing to press"; it is never used for two buttons side by side.
 */
const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded font-medium transition-colors " +
    "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 " +
    "focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-50",
  {
    variants: {
      variant: {
        solid: "bg-primary text-primary-foreground hover:bg-primary-hover",
        accent: "bg-accent text-accent-foreground hover:bg-accent-hover",
        outline: "border border-border-strong bg-surface text-text-primary hover:bg-surface-muted",
        ghost: "text-text-secondary hover:bg-surface-muted hover:text-text-primary",
        danger: "border border-danger/40 bg-surface text-danger hover:bg-danger-muted",
      },
      // Touch targets: roughly 44px on a phone, the original desktop density from sm up.
      // min-h + auto height rather than a taller fixed height, so nothing shifts on desktop.
      size: {
        sm: "min-h-11 px-3 py-1.5 text-xs sm:h-8 sm:min-h-0 sm:py-0",
        md: "min-h-11 px-4 py-2 text-sm sm:h-10 sm:min-h-0 sm:py-0",
        lg: "min-h-11 px-5 py-2 text-sm sm:h-11 sm:min-h-0 sm:py-0",
        icon: "h-11 w-11 sm:h-9 sm:w-9",
      },
    },
    defaultVariants: { variant: "solid", size: "md" },
  },
);

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, ...props }, ref) => (
    <button ref={ref} className={cn(buttonVariants({ variant, size }), className)} {...props} />
  ),
);
Button.displayName = "Button";

export { Button, buttonVariants };
