import { LogOut } from "lucide-react";
import { signOutAction } from "@/app/auth/actions";

/**
 * Account block at the foot of the rail: who is signed in and the one action that
 * belongs to the account rather than the business. Switching business lives on the
 * plate above, next to the business it switches.
 */
export function AccountMenu({ email, fullName }: { email: string | null; fullName: string | null }) {
  const name = fullName?.trim() || email || "Kullanıcı";
  return (
    <div className="flex items-center justify-between gap-3">
      <div className="min-w-0">
        <p className="truncate text-sm leading-tight text-text-primary">{name}</p>
        {fullName && email ? <p className="mt-0.5 truncate text-2xs text-text-muted">{email}</p> : null}
      </div>
      <form action={signOutAction}>
        <button
          type="submit"
          title="Çıkış"
          className="inline-flex h-9 w-9 shrink-0 items-center justify-center rounded text-text-muted transition-colors hover:bg-surface-muted hover:text-text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
        >
          <LogOut aria-hidden className="h-4 w-4 stroke-[1.5]" />
          <span className="sr-only">Çıkış</span>
        </button>
      </form>
    </div>
  );
}
