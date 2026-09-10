"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  LayoutGrid,
  Shirt,
  Boxes,
  Truck,
  PackagePlus,
  ScanLine,
  Users,
  BookmarkCheck,
  BarChart3,
  Settings,
  type LucideIcon,
} from "lucide-react";
import { cn } from "@/lib/utils";

type NavItem = { label: string; icon: LucideIcon; href?: string };

/**
 * Items without an href are modules that do not exist yet and stay inert.
 * A link appears only once its module is actually reachable.
 */
const NAV: NavItem[] = [
  { label: "Panel", icon: LayoutGrid, href: "/app" },
  { label: "Ürünler", icon: Shirt, href: "/app/urunler" },
  { label: "Mal Kabul", icon: PackagePlus, href: "/app/mal-kabul" },
  { label: "Stok", icon: Boxes, href: "/app/stok" },
  { label: "Tedarikçiler", icon: Truck, href: "/app/tedarikciler" },
  { label: "Kasa", icon: ScanLine },
  { label: "Müşteriler", icon: Users },
  { label: "Rezervasyonlar", icon: BookmarkCheck },
  { label: "Raporlar", icon: BarChart3 },
  { label: "Ayarlar", icon: Settings, href: "/app/ayarlar" },
];

export function PrimaryNav() {
  const pathname = usePathname();

  return (
    <nav aria-label="Ana menü" className="flex-1 px-2 pb-4 lg:px-3">
      <ul className="flex flex-wrap gap-1 lg:block lg:space-y-0.5">
        {NAV.map(({ label, icon: Icon, href }) => {
          const isActive = href
            ? href === "/app"
              ? pathname === "/app"
              : pathname === href || pathname.startsWith(`${href}/`)
            : false;

          return (
            <li key={label}>
              {href ? (
                <Link
                  href={href}
                  aria-current={isActive ? "page" : undefined}
                  className={cn(
                    "flex items-center gap-2.5 rounded px-3 py-2 text-sm transition-colors",
                    "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent",
                    isActive
                      ? "bg-accent-soft font-medium text-accent"
                      : "text-ink-70 hover:bg-panel hover:text-ink",
                  )}
                >
                  <Icon aria-hidden className="h-4 w-4 shrink-0 stroke-[1.5]" />
                  <span className="truncate">{label}</span>
                </Link>
              ) : (
                <span
                  aria-disabled="true"
                  title="Bu bölüm henüz açılmadı"
                  className={cn(
                    "cursor-not-allowed items-center gap-2.5 rounded px-3 py-2 text-sm text-muted/70",
                    // On a phone the nav is a wrap-around block at the top of every screen;
                    // items that cannot be tapped would push the actual content below the fold.
                    "hidden lg:flex",
                  )}
                >
                  <Icon aria-hidden className="h-4 w-4 shrink-0 stroke-[1.5]" />
                  <span className="truncate">{label}</span>
                </span>
              )}
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
