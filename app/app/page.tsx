import Link from "next/link";
import { Shirt, PackagePlus, Boxes, Truck } from "lucide-react";
import { requireTenant } from "@/lib/tenant";

/**
 * Landing screen after sign-in.
 *
 * The business, branch and role already sit in the shell header, so repeating them here
 * would be the same information twice. This screen answers "what can I do right now"
 * instead, and it lists only the modules that are actually open.
 */
const MODULES = [
  {
    href: "/app/urunler",
    icon: Shirt,
    title: "Ürünler",
    body: "Ürün ve varyantları tanımlayın, SKU ve barkod verin.",
  },
  {
    href: "/app/mal-kabul",
    icon: PackagePlus,
    title: "Mal Kabul",
    body: "Tedarikçiden gelen ürünleri belgeye girip stoğa alın.",
  },
  {
    href: "/app/stok",
    icon: Boxes,
    title: "Stok",
    body: "Hangi bedenden kaç adet kaldığını ve hareket geçmişini görün.",
  },
  {
    href: "/app/tedarikciler",
    icon: Truck,
    title: "Tedarikçiler",
    body: "Mal kabul belgelerinin bağlanacağı tedarikçileri yönetin.",
  },
];

export default async function AppHomePage() {
  const { profile, user } = await requireTenant();
  const name = profile.full_name?.trim() || user.email?.split("@")[0] || "";

  return (
    <div className="max-w-3xl space-y-8">
      <header>
        <h2 className="font-serif text-xl leading-tight tracking-tightish">
          {name ? `Hoş geldiniz, ${name}` : "Hoş geldiniz"}
        </h2>
        <p className="mt-1 text-xs leading-relaxed text-muted">
          Stok, yalnızca işlenmiş mal kabul belgeleriyle oluşur; hiçbir ekranda elle stok girişi yoktur.
        </p>
      </header>

      <ul className="grid gap-3 sm:grid-cols-2">
        {MODULES.map(({ href, icon: Icon, title, body }) => (
          <li key={href}>
            <Link
              href={href}
              className="flex h-full gap-3 border border-line p-4 transition-colors hover:border-line-strong hover:bg-panel/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
            >
              <Icon aria-hidden className="mt-0.5 h-4 w-4 shrink-0 stroke-[1.5] text-accent" />
              <span>
                <span className="block text-sm font-medium">{title}</span>
                <span className="mt-1 block text-xs leading-relaxed text-muted">{body}</span>
              </span>
            </Link>
          </li>
        ))}
      </ul>

      <p className="border-t border-line pt-4 text-2xs leading-relaxed text-muted">
        Kasa, satış, müşteriler, rezervasyonlar ve raporlar henüz açılmadı; menüde gri görünürler.
      </p>
    </div>
  );
}
