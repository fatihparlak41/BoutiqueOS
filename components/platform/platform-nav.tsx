"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";

const ITEMS: Array<{ href: string; label: string; exact?: boolean }> = [
  { href: "/platform", label: "Genel bakış", exact: true },
  { href: "/platform/basvurular", label: "Başvurular" },
  { href: "/platform/isletmeler", label: "İşletmeler" },
  { href: "/platform/planlar", label: "Planlar" },
];

export function PlatformNav({ pending }: { pending: number }) {
  const pathname = usePathname();
  return (
    <nav aria-label="Platform" className="-mb-px flex gap-1 overflow-x-auto text-sm">
      {ITEMS.map((item) => {
        const active = item.exact ? pathname === item.href : pathname.startsWith(item.href);
        return (
          <Link
            key={item.href}
            href={item.href}
            aria-current={active ? "page" : undefined}
            className={cn(
              "flex items-center gap-1.5 whitespace-nowrap border-b-2 px-3 py-2.5 transition-colors",
              active ? "border-accent text-text-primary" : "border-transparent text-text-muted hover:text-text-primary",
            )}
          >
            {item.label}
            {item.href === "/platform/basvurular" && pending > 0 ? (
              <span className="rounded-full bg-accent px-1.5 text-2xs font-medium leading-4 text-accent-foreground" data-numeric>
                {pending}
              </span>
            ) : null}
          </Link>
        );
      })}
    </nav>
  );
}
