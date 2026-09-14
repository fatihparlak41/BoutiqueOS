import * as React from "react";
import { cn } from "@/lib/utils";

/**
 * The native select keeps its platform chevron on purpose: a custom arrow would need a
 * background-image arbitrary value, and the native control behaves better on mobile.
 */
const Select = React.forwardRef<HTMLSelectElement, React.SelectHTMLAttributes<HTMLSelectElement>>(
  ({ className, children, ...props }, ref) => (
    <select
      ref={ref}
      className={cn(
        "h-11 w-full rounded border border-border-strong bg-surface px-2.5 text-sm text-text-primary sm:h-10",
        "focus-visible:border-accent focus-visible:outline-none focus-visible:ring-2",
        "focus-visible:ring-ring/60 disabled:opacity-50 aria-[invalid=true]:border-danger",
        className,
      )}
      {...props}
    >
      {children}
    </select>
  ),
);
Select.displayName = "Select";

export { Select };
