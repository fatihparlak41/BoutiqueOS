"use client";

import { useActionState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import {
  publishImageAction,
  publishProductAction,
  saveStorefrontAction,
  setProductWebAction,
  setVariantWebAction,
  toggleFeaturedAction,
} from "@/app/app/online-magaza/actions";
import { STOREFRONT_IDLE, type AdminProduct, type StorefrontSettings } from "@/lib/storefront/model";

function Feedback({ error, ok, okText, message }: { error: string | null; ok: boolean; okText: string; message?: string }) {
  if (error) return <p className="text-xs text-danger" role="alert">{error}</p>;
  if (ok) return <p className="text-xs text-text-secondary" role="status">{message ?? okText}</p>;
  return null;
}

export function StorefrontSettingsForm({ settings, branches, siteOrigin }: { settings: StorefrontSettings | null; branches: Array<{ id: string; name: string; is_default: boolean }>; siteOrigin: string }) {
  const [state, formAction, pending] = useActionState(saveStorefrontAction, STOREFRONT_IDLE);
  return (
    <form action={formAction} className="grid grid-cols-1 gap-4 rounded border border-border bg-surface p-4 sm:grid-cols-2">
      <label className="flex items-center gap-2 text-sm text-text-primary sm:col-span-2">
        <input type="checkbox" name="enabled" defaultChecked={settings?.enabled ?? false} /> Mağaza yayında
        <span className="text-xs text-text-muted">— kapalıyken adres 404 verir; ürünler ve ayarlar korunur.</span>
      </label>
      <div className="space-y-1.5">
        <Label htmlFor="sf-name">Mağaza adı</Label>
        <Input id="sf-name" name="store_name" defaultValue={settings?.store_name ?? ""} maxLength={80} required />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="sf-slug">Mağaza adresi</Label>
        <Input id="sf-slug" name="slug" defaultValue={settings?.slug ?? ""} pattern="[a-z0-9][a-z0-9-]{1,48}[a-z0-9]" required />
        <p className="text-2xs text-text-muted" data-numeric>{siteOrigin}/shop/{settings?.slug ?? "…"}</p>
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="sf-tagline">Slogan <span className="text-text-muted">(isteğe bağlı)</span></Label>
        <Input id="sf-tagline" name="tagline" defaultValue={settings?.tagline ?? ""} maxLength={160} />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="sf-announce">Duyuru şeridi <span className="text-text-muted">(isteğe bağlı)</span></Label>
        <Input id="sf-announce" name="announcement" defaultValue={settings?.announcement ?? ""} maxLength={200} />
      </div>
      <div className="space-y-1.5 sm:col-span-2">
        <Label htmlFor="sf-about">Hakkında <span className="text-text-muted">(isteğe bağlı)</span></Label>
        <Textarea id="sf-about" name="about" defaultValue={settings?.about ?? ""} rows={3} maxLength={2000} />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="sf-ig">Instagram kullanıcı adı</Label>
        <Input id="sf-ig" name="instagram" defaultValue={settings?.instagram ?? ""} maxLength={30} />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="sf-wa">WhatsApp numarası</Label>
        <Input id="sf-wa" name="whatsapp" defaultValue={settings?.whatsapp ?? ""} inputMode="tel" placeholder="+90…" />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="sf-email">İletişim e-postası</Label>
        <Input id="sf-email" name="contact_email" type="email" defaultValue={settings?.contact_email ?? ""} />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="sf-phone">Telefon</Label>
        <Input id="sf-phone" name="contact_phone" defaultValue={settings?.contact_phone ?? ""} maxLength={32} />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="sf-branch">Stok şubesi</Label>
        <Select id="sf-branch" name="fulfillment_branch_id" defaultValue={settings?.fulfillment_branch_id ?? ""}>
          <option value="">Varsayılan şube</option>
          {branches.map((b) => (
            <option key={b.id} value={b.id}>{b.name}{b.is_default ? " (varsayılan)" : ""}</option>
          ))}
        </Select>
        <p className="text-2xs text-text-muted">Müsaitlik bu şubenin satılabilir stoğu eksi aktif rezervasyonlardır.</p>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1.5">
          <Label htmlFor="sf-display">Stok gösterimi</Label>
          <Select id="sf-display" name="stock_display" defaultValue={settings?.stock_display ?? "state"}>
            <option value="state">Durum (Stokta / Son ürünler / Tükendi)</option>
            <option value="exact">Adet</option>
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="sf-low">“Son ürünler” eşiği</Label>
          <Input id="sf-low" name="low_stock_threshold" type="number" min={1} max={50} defaultValue={settings?.low_stock_threshold ?? 3} />
        </div>
      </div>
      <div className="flex items-center gap-3 sm:col-span-2">
        <Button type="submit" size="sm" disabled={pending}>{pending ? "Kaydediliyor…" : "Kaydet"}</Button>
        <Feedback error={state.error} ok={state.ok} okText="Kaydedildi." />
      </div>
    </form>
  );
}

export function PublishToggle({ productId, published, disabled }: { productId: string; published: boolean; disabled?: boolean }) {
  const [state, formAction, pending] = useActionState(publishProductAction, STOREFRONT_IDLE);
  return (
    <form action={formAction} className="space-y-1">
      <input type="hidden" name="product_id" value={productId} />
      <input type="hidden" name="published" value={published ? "false" : "true"} />
      <Button type="submit" size="sm" variant={published ? "outline" : "solid"} disabled={pending || disabled}>
        {pending ? "…" : published ? "Yayından kaldır" : "Online mağazada yayınla"}
      </Button>
      <Feedback error={state.error} ok={state.ok} okText={published ? "Yayından kaldırıldı." : "Yayınlandı."} message={state.message} />
    </form>
  );
}

export function FeaturedToggle({ productId, featured }: { productId: string; featured: boolean }) {
  const [state, formAction, pending] = useActionState(toggleFeaturedAction, STOREFRONT_IDLE);
  return (
    <form action={formAction}>
      <input type="hidden" name="product_id" value={productId} />
      <input type="hidden" name="featured" value={featured ? "false" : "true"} />
      <Button type="submit" size="sm" variant="ghost" disabled={pending}>{featured ? "Öne çıkarmayı kaldır" : "Öne çıkar"}</Button>
      {state.error ? <p className="text-xs text-danger" role="alert">{state.error}</p> : null}
    </form>
  );
}

export function ProductWebForm({ product }: { product: AdminProduct }) {
  const [state, formAction, pending] = useActionState(setProductWebAction, STOREFRONT_IDLE);
  return (
    <form action={formAction} className="grid grid-cols-1 gap-4 rounded border border-border bg-surface p-4 sm:grid-cols-2">
      <input type="hidden" name="product_id" value={product.id} />
      <div className="space-y-1.5">
        <Label htmlFor="pw-title">Web başlığı <span className="text-text-muted">(boşsa ürün adı)</span></Label>
        <Input id="pw-title" name="web_title" defaultValue={product.web_title ?? ""} maxLength={120} placeholder={product.name} />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="pw-slug">Ürün adresi</Label>
        <Input id="pw-slug" name="web_slug" defaultValue={product.web_slug ?? ""} placeholder="yayınlandığında üretilir" />
      </div>
      <div className="space-y-1.5 sm:col-span-2">
        <Label htmlFor="pw-desc">Web açıklaması <span className="text-text-muted">(boşsa ürün açıklaması)</span></Label>
        <Textarea id="pw-desc" name="web_description" defaultValue={product.web_description ?? ""} rows={4} maxLength={4000} placeholder={product.description ?? ""} />
      </div>
      <label className="flex items-center gap-2 text-sm text-text-primary">
        <input type="checkbox" name="web_featured" defaultChecked={product.web_featured} /> Ana sayfada öne çıkar
      </label>
      <div className="space-y-1.5">
        <Label htmlFor="pw-sort">Sıra <span className="text-text-muted">(küçük önce)</span></Label>
        <Input id="pw-sort" name="web_sort_order" type="number" defaultValue={product.web_sort_order} className="w-28" />
      </div>
      <div className="flex items-center gap-3 sm:col-span-2">
        <Button type="submit" size="sm" disabled={pending}>{pending ? "Kaydediliyor…" : "Kaydet"}</Button>
        <Feedback error={state.error} ok={state.ok} okText="Kaydedildi." />
      </div>
    </form>
  );
}

export function VariantWebToggle({ variantId, enabled }: { variantId: string; enabled: boolean }) {
  const [state, formAction, pending] = useActionState(setVariantWebAction, STOREFRONT_IDLE);
  return (
    <form action={formAction}>
      <input type="hidden" name="variant_id" value={variantId} />
      <input type="hidden" name="enabled" value={enabled ? "false" : "true"} />
      <Button type="submit" size="sm" variant="outline" disabled={pending}>{enabled ? "Webden kaldır" : "Webde göster"}</Button>
      {state.error ? <p className="text-xs text-danger" role="alert">{state.error}</p> : null}
    </form>
  );
}

export function ImagePublishToggle({ imageId, published, allowed }: { imageId: string; published: boolean; allowed: boolean }) {
  const [state, formAction, pending] = useActionState(publishImageAction, STOREFRONT_IDLE);
  if (!allowed) return <span className="text-xs text-text-muted">Özel — yayınlanmaz</span>;
  return (
    <form action={formAction}>
      <input type="hidden" name="image_id" value={imageId} />
      <input type="hidden" name="unpublish" value={published ? "true" : "false"} />
      <Button type="submit" size="sm" variant={published ? "ghost" : "outline"} disabled={pending}>{pending ? "…" : published ? "Yayından kaldır" : "Yayınla"}</Button>
      {state.error ? <p className="text-xs text-danger" role="alert">{state.error}</p> : null}
    </form>
  );
}
