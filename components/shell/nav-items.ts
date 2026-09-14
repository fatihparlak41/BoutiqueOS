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

export type NavItem = { label: string; icon: LucideIcon; href?: string };
export type NavGroup = { label: string; items: NavItem[] };

/**
 * Navigation, grouped by what a person is doing. Items without an href are modules that
 * do not exist yet and stay inert; a link appears only once its module is reachable.
 * Visibility is not a permission: a page a role may not use redirects on the server.
 */
export const NAV_GROUPS: NavGroup[] = [
  {
    label: "Mağaza",
    items: [
      { label: "Panel", icon: LayoutGrid, href: "/app" },
      { label: "Ürünler", icon: Shirt, href: "/app/urunler" },
      { label: "Stok", icon: Boxes, href: "/app/stok" },
    ],
  },
  {
    label: "Tedarik",
    items: [
      { label: "Mal Kabul", icon: PackagePlus, href: "/app/mal-kabul" },
      { label: "Tedarikçiler", icon: Truck, href: "/app/tedarikciler" },
    ],
  },
  {
    label: "Satış",
    items: [
      { label: "Kasa", icon: ScanLine },
      { label: "Müşteriler", icon: Users },
      { label: "Rezervasyonlar", icon: BookmarkCheck },
    ],
  },
  {
    label: "Yönetim",
    items: [
      { label: "Raporlar", icon: BarChart3 },
      { label: "Ayarlar", icon: Settings, href: "/app/ayarlar" },
    ],
  },
];

export function isNavActive(pathname: string, href: string): boolean {
  return href === "/app" ? pathname === "/app" : pathname === href || pathname.startsWith(`${href}/`);
}
