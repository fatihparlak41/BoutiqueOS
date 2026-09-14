import Link from "next/link";
import { ArrowLeftRight } from "lucide-react";
import { ROLE_LABELS } from "@/lib/roles";
import type { TenantContext } from "@/lib/tenant";
import { cn } from "@/lib/utils";

/**
 * The tenant's plate: the one place in the shell where the serif appears. Business name
 * set editorially, role and branch underneath, a single plum rule. When the account
 * belongs to more than one business the plate is the switcher.
 *
 * Every value here comes from the server-resolved tenant context — none from client state.
 */
export function BusinessPlate({
  active,
  branch,
  canSwitch,
  className,
}: {
  active: TenantContext["active"];
  branch: TenantContext["branch"];
  canSwitch: boolean;
  className?: string;
}) {
  const body = (
    <>
      <span className="block truncate font-serif text-2xl font-semibold leading-tight tracking-tightish text-text-primary">
        {active.business_name}
      </span>
      <span className="mt-1 block truncate text-xs text-text-muted">
        {ROLE_LABELS[active.role]}
        {branch ? `, ${branch.name}` : ", şube atanmamış"}
      </span>
    </>
  );

  const base = "block border-l-2 border-accent pl-3";

  if (!canSwitch) {
    return <div className={cn(base, className)}>{body}</div>;
  }

  return (
    <Link
      href="/select-business"
      title="İşletme değiştir"
      className={cn(
        base,
        "group -ml-px rounded-r py-0.5 pr-2 transition-colors hover:bg-surface-muted",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
        className,
      )}
    >
      <span className="flex items-start justify-between gap-2">
        <span className="min-w-0">{body}</span>
        <ArrowLeftRight
          aria-hidden
          className="mt-1.5 h-3.5 w-3.5 shrink-0 stroke-[1.5] text-text-muted group-hover:text-text-primary"
        />
      </span>
      <span className="sr-only">İşletme değiştir</span>
    </Link>
  );
}
