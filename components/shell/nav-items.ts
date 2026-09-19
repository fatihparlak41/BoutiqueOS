import {
  BarChart3,
  Boxes,
  ClipboardList,
  CreditCard,
  Globe,
  Home,
  Lightbulb,
  PackagePlus,
  ScanLine,
  Settings,
  Shirt,
  ShoppingBag,
  Truck,
  Undo2,
  UserCog,
  Users,
  BookmarkCheck,
  type LucideIcon,
} from "lucide-react";
import type { UserRole } from "@/lib/tenant";

/**
 * Navigation, grouped by what a person is doing, filtered by what their role may open.
 * The role sets mirror the pages' own guards (each page still redirects on its own; the
 * menu only stops showing doors that would not open):
 *
 *   selling      owner · manager · sales_staff   → Kasa, İade, Rezervasyonlar, Müşteriler, Online siparişler
 *   procurement  owner · manager · stock_staff   → Mal kabul, Satın alma, Tedarikçiler
 *   everyone                                     → Ana sayfa, Ürünler, Stok, Raporlar, Moda analizi, Ayarlar
 *   manager+     owner · manager                 → Online mağaza, Ekip
 *   owner                                        → Abonelik
 */
export type NavItem = { label: string; icon: LucideIcon; href: string; roles: readonly UserRole[] };
export type NavGroup = { label: string; items: NavItem[] };

const ALL: readonly UserRole[] = ["owner", "manager", "sales_staff", "stock_staff"];
const SELLING: readonly UserRole[] = ["owner", "manager", "sales_staff"];
const PROCUREMENT: readonly UserRole[] = ["owner", "manager", "stock_staff"];
const MANAGER: readonly UserRole[] = ["owner", "manager"];
const OWNER: readonly UserRole[] = ["owner"];

export const NAV_GROUPS: NavGroup[] = [
  {
    label: "Genel",
    items: [{ label: "Ana sayfa", icon: Home, href: "/app", roles: ALL }],
  },
  {
    label: "Satış",
    items: [
      { label: "Kasa", icon: ScanLine, href: "/app/pos", roles: SELLING },
      { label: "Rezervasyonlar", icon: BookmarkCheck, href: "/app/rezervasyonlar", roles: SELLING },
      { label: "Online siparişler", icon: ShoppingBag, href: "/app/online-siparisler", roles: SELLING },
      { label: "Müşteriler", icon: Users, href: "/app/musteriler", roles: SELLING },
      { label: "İade / Değişim", icon: Undo2, href: "/app/pos/iade", roles: SELLING },
    ],
  },
  {
    label: "Ürünler",
    items: [
      { label: "Ürünler", icon: Shirt, href: "/app/urunler", roles: ALL },
      { label: "Stok", icon: Boxes, href: "/app/stok", roles: ALL },
      { label: "Mal kabul", icon: PackagePlus, href: "/app/mal-kabul", roles: PROCUREMENT },
      { label: "Satın alma", icon: ClipboardList, href: "/app/satin-alma", roles: PROCUREMENT },
      { label: "Tedarikçiler", icon: Truck, href: "/app/tedarikciler", roles: PROCUREMENT },
    ],
  },
  {
    label: "Raporlar",
    items: [
      { label: "Raporlar", icon: BarChart3, href: "/app/raporlar", roles: ALL },
      { label: "Moda analizi", icon: Lightbulb, href: "/app/analiz", roles: ALL },
    ],
  },
  {
    label: "Yönetim",
    items: [
      { label: "Online mağaza", icon: Globe, href: "/app/online-magaza", roles: MANAGER },
      { label: "Ekip", icon: UserCog, href: "/app/ayarlar/ekip", roles: MANAGER },
      { label: "Ayarlar", icon: Settings, href: "/app/ayarlar", roles: ALL },
      { label: "Abonelik", icon: CreditCard, href: "/app/ayarlar/abonelik", roles: OWNER },
    ],
  },
];

export function navGroupsFor(role: UserRole): NavGroup[] {
  return NAV_GROUPS.map((g) => ({ ...g, items: g.items.filter((i) => i.roles.includes(role)) })).filter((g) => g.items.length > 0);
}

/**
 * Active-route test. Nested pages belong to their parent item, except where a more
 * specific item exists (İade under Kasa, Ekip / Abonelik under Ayarlar): the most
 * specific matching href wins, so exactly one item lights up.
 */
export function isNavActive(pathname: string, href: string, all: readonly string[] = NAV_GROUPS.flatMap((g) => g.items.map((i) => i.href))): boolean {
  if (href === "/app") return pathname === "/app";
  if (!(pathname === href || pathname.startsWith(`${href}/`))) return false;
  const moreSpecific = all.some((other) => other !== href && other.length > href.length && other.startsWith(`${href}/`) && (pathname === other || pathname.startsWith(`${other}/`)));
  return !moreSpecific;
}

/** The phone's bottom bar: up to five doors the role can open; "Menü" is added by the bar itself. */
export function bottomNavFor(role: UserRole): NavItem[] {
  const wanted = ["/app/pos", "/app/urunler", "/app/stok", "/app/online-siparisler", "/app/mal-kabul", "/app/raporlar"];
  const items = NAV_GROUPS.flatMap((g) => g.items).filter((i) => i.roles.includes(role));
  return wanted.map((href) => items.find((i) => i.href === href)).filter((i): i is NavItem => !!i).slice(0, 4);
}
