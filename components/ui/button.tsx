import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 rounded font-medium transition-colors " +
    "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 " +
    "focus-visible:ring-offset-paper disabled:pointer-events-none disabled:opacity-50",
  {
    variants: {
      variant: {
        solid: "bg-ink text-paper hover:bg-ink-70",
        outline: "border border-line-strong bg-transparent text-ink hover:bg-panel",
        ghost: "text-muted hover:bg-panel hover:text-ink",
      },
      // Touch targets: roughly 44px on a phone, the original desktop density from sm up.
      // min-h + auto height rather than a taller fixed height, so nothing shifts on desktop.
      size: {
        sm: "min-h-11 px-3 py-1.5 text-xs sm:h-8 sm:min-h-0 sm:py-0",
        md: "min-h-11 px-4 py-2 text-sm sm:h-10 sm:min-h-0 sm:py-0",
        lg: "min-h-11 px-5 py-2 text-sm sm:h-11 sm:min-h-0 sm:py-0",
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
