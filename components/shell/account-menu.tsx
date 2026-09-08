import Link from "next/link";
import { signOutAction } from "@/app/auth/actions";
import { Button } from "@/components/ui/button";

export function AccountMenu({
  email,
  fullName,
  canSwitchBusiness,
}: {
  email: string | null;
  fullName: string | null;
  canSwitchBusiness: boolean;
}) {
  return (
    <div className="flex items-center gap-3">
      <div className="hidden text-right sm:block">
        <p className="text-sm leading-tight">{fullName ?? email ?? "Kullanıcı"}</p>
        {fullName && email ? <p className="text-xs text-muted">{email}</p> : null}
      </div>

      {canSwitchBusiness ? (
        <Link
          href="/select-business"
          className="rounded px-2 py-1 text-xs text-muted underline-offset-4 hover:text-ink hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
        >
          İşletme değiştir
        </Link>
      ) : null}

      <form action={signOutAction}>
        <Button type="submit" variant="outline" size="sm">
          Çıkış
        </Button>
      </form>
    </div>
  );
}
