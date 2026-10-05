"use client";

import { useActionState, useState, useTransition } from "react";
import Image from "next/image";
import { useRouter } from "next/navigation";
import { Badge } from "@/components/ui/badge";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import {
  publishImageAction,
  publishProductAction,
  removeStoreMediaAction,
  saveStorefrontAction,
  setProductWebAction,
  setVariantWebAction,
  toggleFeaturedAction,
  uploadStoreMediaAction,
} from "@/app/app/online-magaza/actions";
import { publicImageUrl } from "@/lib/shop/model";
import { STOREFRONT_IDLE, type AdminProduct, type StorefrontSettings } from "@/lib/storefront/model";

function Feedback({ error, ok, okText, message }: { error: string | null; ok: boolean; okText: string; message?: string }) {
  if (error) return <p className="text-xs text-danger" role="alert">{error}</p>;
  if (ok) return <p className="text-xs text-text-secondary" role="status">{message ?? okText}</p>;
  return null;
}

const SETTINGS_FORM = "sf-settings";

function Group({ title, note, children }: { title: string; note?: string; children: React.ReactNode }) {
  return (
    <section className="space-y-3 rounded border border-border bg-surface p-4" aria-label={title}>
      <div className="space-y-0.5">
        <h2 className="text-2xs font-medium uppercase tracking-[0.12em] text-text-muted">{title}</h2>
        {note ? <p className="text-xs text-text-secondary">{note}</p> : null}
      </div>
      {children}
    </section>
  );
}

/**
 * Store settings, grouped as the merchant thinks about them: the store itself, how it looks,
 * how customers reach it, stock and orders. All text fields belong to ONE form (the `form`
 * attribute ties the fields of every group to it) and are saved together by one RPC; the
 * logo and the hero image are separate immediate uploads. Not a website builder.
 */
export function StorefrontSettingsForm({ settings, branches, siteOrigin, storeUrl }: { settings: StorefrontSettings | null; branches: Array<{ id: string; name: string; is_default: boolean }>; siteOrigin: string; storeUrl: string | null }) {
  const [state, formAction, pending] = useActionState(saveStorefrontAction, STOREFRONT_IDLE);
  const f = SETTINGS_FORM;
  return (
    <div className="space-y-4" data-testid="storefront-settings">
      <Group title="Mağaza">
        <div className="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm">
          <span className="text-text-secondary">Mağaza durumu:</span>
          <Badge tone={settings?.enabled ? "success" : "neutral"}>{settings ? (settings.enabled ? "Yayında" : "Kapalı") : "Henüz kurulmadı"}</Badge>
          {storeUrl ? (
            <a href={storeUrl} target="_blank" rel="noopener noreferrer" className="ml-auto text-sm underline underline-offset-4" data-testid="storefront-view">
              Mağazayı görüntüle ↗
            </a>
          ) : null}
        </div>
        <label className="flex items-center gap-2 text-sm text-text-primary">
          <input type="checkbox" name="enabled" form={f} defaultChecked={settings?.enabled ?? false} /> Mağaza yayında
          <span className="text-xs text-text-muted">— kapalıyken adres 404 verir; ürünler ve ayarlar korunur.</span>
        </label>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div className="space-y-1.5">
            <Label htmlFor="sf-name">Mağaza adı</Label>
            <Input id="sf-name" name="store_name" form={f} defaultValue={settings?.store_name ?? ""} maxLength={80} required />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="sf-slug">Web adresi</Label>
            <Input id="sf-slug" name="slug" form={f} defaultValue={settings?.slug ?? ""} pattern="[a-z0-9][a-z0-9-]{1,48}[a-z0-9]" required />
            <p className="text-2xs text-text-muted" data-numeric>{siteOrigin}/shop/{settings?.slug ?? "…"}</p>
          </div>
        </div>
      </Group>

      <Group title="Görünüm" note="Logo ve ana görsel seçildiği anda yüklenir; metinler en alttaki Kaydet ile kaydedilir.">
        {settings ? (
          <div className="grid grid-cols-1 gap-6 md:grid-cols-2">
            <StoreMediaField kind="logo" path={settings.logo_path} />
            <StoreMediaField kind="hero" path={settings.hero_image_path} />
          </div>
        ) : (
          <p className="text-xs text-text-muted">Logo ve ana görsel, mağaza ayarları ilk kez kaydedildikten sonra eklenir.</p>
        )}
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div className="space-y-1.5">
            <Label htmlFor="sf-hero-heading">Ana başlık <span className="text-text-muted">(isteğe bağlı)</span></Label>
            <Input id="sf-hero-heading" name="hero_heading" form={f} defaultValue={settings?.hero_heading ?? ""} maxLength={80} placeholder={settings?.store_name ?? ""} />
            <p className="text-2xs text-text-muted">Ana görselin yanında görünür; boşsa mağaza adı kullanılır.</p>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="sf-tagline">Slogan <span className="text-text-muted">(isteğe bağlı)</span></Label>
            <Input id="sf-tagline" name="tagline" form={f} defaultValue={settings?.tagline ?? ""} maxLength={160} />
          </div>
          <div className="space-y-1.5 sm:col-span-2">
            <Label htmlFor="sf-announce">Duyuru <span className="text-text-muted">(isteğe bağlı — sayfanın en üstünde tek satır)</span></Label>
            <Input id="sf-announce" name="announcement" form={f} defaultValue={settings?.announcement ?? ""} maxLength={200} />
          </div>
          <div className="space-y-1.5 sm:col-span-2">
            <Label htmlFor="sf-about">Hakkında <span className="text-text-muted">(isteğe bağlı — ana sayfanın altında kısa bir metin)</span></Label>
            <Textarea id="sf-about" name="about" form={f} defaultValue={settings?.about ?? ""} rows={3} maxLength={2000} />
          </div>
        </div>
      </Group>

      <Group title="İletişim">
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div className="space-y-1.5">
            <Label htmlFor="sf-ig">Instagram kullanıcı adı</Label>
            <Input id="sf-ig" name="instagram" form={f} defaultValue={settings?.instagram ?? ""} maxLength={30} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="sf-wa">WhatsApp numarası</Label>
            <Input id="sf-wa" name="whatsapp" form={f} defaultValue={settings?.whatsapp ?? ""} inputMode="tel" placeholder="+90…" />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="sf-email">E-posta</Label>
            <Input id="sf-email" name="contact_email" form={f} type="email" defaultValue={settings?.contact_email ?? ""} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="sf-phone">Telefon</Label>
            <Input id="sf-phone" name="contact_phone" form={f} defaultValue={settings?.contact_phone ?? ""} maxLength={32} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="sf-branch">Teslim şubesi</Label>
            <Select id="sf-branch" name="fulfillment_branch_id" form={f} defaultValue={settings?.fulfillment_branch_id ?? ""}>
              <option value="">Varsayılan şube</option>
              {branches.map((b) => (
                <option key={b.id} value={b.id}>{b.name}{b.is_default ? " (varsayılan)" : ""}</option>
              ))}
            </Select>
            <p className="text-2xs text-text-muted">Siparişler bu şubeden teslim edilir; müsaitlik bu şubenin satılabilir stoğu eksi aktif ayırmalardır.</p>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="sf-pickup">Teslim notu <span className="text-text-muted">(isteğe bağlı)</span></Label>
            <Input id="sf-pickup" name="pickup_note" form={f} defaultValue={settings?.pickup_note ?? ""} maxLength={300} placeholder="ör. Hafta içi 10:00–19:00" />
          </div>
        </div>
      </Group>

      <Group title="Stok ve sipariş">
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div className="space-y-1.5">
            <Label htmlFor="sf-display">Stok gösterimi</Label>
            <Select id="sf-display" name="stock_display" form={f} defaultValue={settings?.stock_display ?? "state"}>
              <option value="state">Durum (Stokta / Son ürünler / Tükendi)</option>
              <option value="exact">Adet</option>
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="sf-low">“Son ürünler” eşiği</Label>
            <Input id="sf-low" name="low_stock_threshold" form={f} type="number" min={1} max={50} defaultValue={settings?.low_stock_threshold ?? 3} />
          </div>
          <label className="flex items-center gap-2 text-sm text-text-primary sm:col-span-2">
            <input type="checkbox" name="orders_enabled" form={f} defaultChecked={settings?.orders_enabled ?? true} /> Sipariş talebi alınsın
            <span className="text-xs text-text-muted">— müşteri ad ve telefonla talep bırakır; ürünler ayrılır; ödeme mağazada teslim sırasında yapılır.</span>
          </label>
          <div className="space-y-1.5">
            <Label htmlFor="sf-hold">Ayırma süresi (dakika)</Label>
            <Input id="sf-hold" name="order_hold_minutes" form={f} type="number" min={30} max={10080} defaultValue={settings?.order_hold_minutes ?? 1440} />
            <p className="text-2xs text-text-muted">Talepten itibaren ürünler bu kadar süre ayrılır; onay süreyi yeniden başlatır. 1440 = 24 saat.</p>
          </div>
        </div>
      </Group>

      <form id={f} action={formAction} className="flex items-center gap-3 border-t border-border pt-4" data-testid="storefront-save">
        <Button type="submit" size="sm" disabled={pending}>{pending ? "Kaydediliyor…" : "Kaydet"}</Button>
        <Feedback error={state.error} ok={state.ok} okText="Kaydedildi." />
      </form>
    </div>
  );
}

const MEDIA_COPY = {
  logo: {
    title: "Logo",
    empty: "Logo yok — mağaza adı yazıyla gösterilir.",
    hint: "Şeffaf PNG veya WebP önerilir; yatay logolar en iyi sonucu verir. En fazla 4 MB.",
    remove: "Logo kaldırılsın mı?",
    removeText: "Mağaza adı yazıyla gösterilir. Dosya mağazadan silinir.",
  },
  hero: {
    title: "Ana görsel",
    empty: "Ana görsel yok — ana sayfa mağaza adı ve güncel ürün fotoğraflarıyla açılır.",
    hint: "Dikey (portre) kadraj en iyisidir: telefonda 4:5, masaüstünde 3:4 gösterilir. En az 1600 px genişlik önerilir. JPEG, PNG veya WebP; en fazla 4 MB.",
    remove: "Ana görsel kaldırılsın mı?",
    removeText: "Ana sayfa mağaza adı ve güncel ürün fotoğraflarıyla açılır. Dosya mağazadan silinir.",
  },
} as const;

/** Logo / hero: preview, upload (or replace) right away, remove behind a confirmation. */
export function StoreMediaField({ kind, path }: { kind: "logo" | "hero"; path: string | null }) {
  const copy = MEDIA_COPY[kind];
  const [state, formAction, uploading] = useActionState(uploadStoreMediaAction, STOREFRONT_IDLE);
  const [confirm, setConfirm] = useState(false);
  const [removing, start] = useTransition();
  const [removeError, setRemoveError] = useState<string | null>(null);
  const router = useRouter();
  const url = publicImageUrl(path);
  const busy = uploading || removing;

  function remove() {
    start(async () => {
      const fd = new FormData();
      fd.set("kind", kind);
      const res = await removeStoreMediaAction(STOREFRONT_IDLE, fd);
      setConfirm(false);
      setRemoveError(res.ok ? null : res.error);
      router.refresh();
    });
  }

  return (
    <div className="space-y-2" data-testid={`store-media-${kind}`}>
      <p className="text-sm font-medium text-text-primary">{copy.title}</p>
      <div className={kind === "hero" ? "relative aspect-[4/5] w-36 overflow-hidden rounded-sm border border-border bg-surface-muted" : "relative h-14 w-48 overflow-hidden rounded-sm border border-border bg-surface-muted"}>
        {url ? (
          <Image src={url} alt="" fill sizes={kind === "hero" ? "144px" : "192px"} className={kind === "hero" ? "object-cover" : "object-contain p-2"} />
        ) : (
          <span className="absolute inset-0 grid place-items-center px-2 text-center text-2xs text-text-muted">Yok</span>
        )}
      </div>
      {!url ? <p className="text-xs text-text-muted">{copy.empty}</p> : null}
      <div className="flex flex-wrap items-center gap-2">
        <form action={formAction}>
          <input type="hidden" name="kind" value={kind} />
          <label className={`inline-flex h-8 cursor-pointer items-center rounded-sm border border-border px-3 text-xs text-text-primary hover:bg-surface-muted ${busy ? "pointer-events-none opacity-60" : ""}`}>
            {uploading ? "Yükleniyor…" : url ? "Değiştir" : "Yükle"}
            <input
              type="file"
              name="file"
              accept="image/jpeg,image/png,image/webp"
              className="sr-only"
              disabled={busy}
              data-testid={`store-media-${kind}-input`}
              onChange={(e) => { if (e.currentTarget.files?.length) e.currentTarget.form?.requestSubmit(); }}
            />
          </label>
        </form>
        {url ? (
          <Button type="button" size="sm" variant="ghost" disabled={busy} onClick={() => setConfirm(true)}>Kaldır</Button>
        ) : null}
      </div>
      <p className="text-2xs text-text-muted">{copy.hint}</p>
      <Feedback error={state.error ?? removeError} ok={state.ok} okText="Kaydedildi." message={state.message} />
      <ConfirmDialog
        open={confirm}
        onClose={() => setConfirm(false)}
        title={copy.remove}
        description={copy.removeText}
        confirmLabel="Kaldır"
        destructive
        busy={removing}
        onConfirm={remove}
      />
    </div>
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
