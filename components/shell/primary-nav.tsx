import {
  LayoutGrid,
  Shirt,
  Boxes,
  Truck,
  ScanLine,
  Users,
  BookmarkCheck,
  BarChart3,
  Settings,
} from "lucide-react";

/**
 * Phase 1 shows the map of the product, not the product. Every item is a placeholder
 * and is deliberately inert until its module is built.
 */
const NAV = [
  { label: "Panel", icon: LayoutGrid },
  { label: "Ürünler", icon: Shirt },
  { label: "Stok", icon: Boxes },
  { label: "Tedarikçiler", icon: Truck },
  { label: "Kasa", icon: ScanLine },
  { label: "Müşteriler", icon: Users },
  { label: "Rezervasyonlar", icon: BookmarkCheck },
  { label: "Raporlar", icon: BarChart3 },
  { label: "Ayarlar", icon: Settings },
] as const;

export function PrimaryNav() {
  return (
    <nav aria-label="Ana menü" className="flex-1 px-2 pb-4 lg:px-3">
      <ul className="flex flex-wrap gap-1 lg:block lg:space-y-0.5">
        {NAV.map(({ label, icon: Icon }) => (
          <li key={label}>
            <span
              aria-disabled="true"
              title="Bu bölüm henüz açılmadı"
              className="flex cursor-not-allowed items-center gap-2.5 rounded px-3 py-2 text-sm text-muted/70"
            >
              <Icon aria-hidden className="h-4 w-4 shrink-0 stroke-[1.5]" />
              <span className="truncate">{label}</span>
            </span>
          </li>
        ))}
      </ul>
    </nav>
  );
}
