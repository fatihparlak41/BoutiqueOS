import * as React from "react";
import { cn } from "@/lib/utils";

const Input = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(
  ({ className, type, ...props }, ref) => (
    <input
      ref={ref}
      type={type}
      className={cn(
        "h-11 w-full rounded border border-border-strong bg-surface px-3 text-sm text-text-primary sm:h-10",
        "placeholder:text-text-muted/70 focus-visible:border-accent focus-visible:outline-none",
        "focus-visible:ring-2 focus-visible:ring-ring/60 disabled:opacity-50",
        "aria-[invalid=true]:border-danger",
        className,
      )}
      {...props}
    />
  ),
);
Input.displayName = "Input";

export { Input };
