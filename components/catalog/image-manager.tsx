"use client";

import { useActionState, useState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Badge } from "@/components/ui/badge";
import { FormMessage } from "@/components/catalog/form-message";
import { ProductThumb } from "@/components/catalog/product-thumb";
import { IMAGE_ROLE_LABELS, type ProductImage, type VariantRow } from "@/lib/catalog/model";
import { IDLE } from "@/lib/catalog/action-state";
import { deleteImageAction, setMainImageAction, uploadImageAction } from "@/app/app/urunler/actions";

/**
 * Product images: upload (main, gallery, a colour's variant image, the garment's label
 * tag), promote one to main, remove. Files go through the server action, which validates
 * type and size and writes under this business's storage prefix; nothing here talks to
 * the bucket directly. Thumbnails are short-lived signed URLs.
 */

function Pending({ label, pendingLabel, variant = "outline" }: { label: string; pendingLabel: string; variant?: "solid" | "outline" | "ghost" | "danger" }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {pending ? pendingLabel : label}
    </Button>
  );
}

function ImageCard({ image, productId, variantLabel, canEdit }: { image: ProductImage; productId: string; variantLabel: string | null; canEdit: boolean }) {
  const [mainState, mainAction] = useActionState(setMainImageAction, IDLE);
  const [delState, delAction] = useActionState(deleteImageAction, IDLE);

  return (
    <li className="flex gap-3 rounded border border-border bg-surface p-3">
      <ProductThumb url={image.url} alt={image.alt_text ?? IMAGE_ROLE_LABELS[image.role]} size="md" />
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <Badge tone={image.role === "product_main" ? "accent" : "neutral"}>{IMAGE_ROLE_LABELS[image.role]}</Badge>
          {variantLabel ? <span className="text-2xs text-text-muted">{variantLabel}</span> : null}
        </div>
        {image.alt_text ? <p className="mt-1 text-xs text-text-secondary">{image.alt_text}</p> : null}
        {image.byte_size ? (
          <p className="mt-1 text-2xs text-text-muted" data-numeric>
            {image.byte_size < 1024 ? "<1" : (image.byte_size / 1024).toFixed(0)} KB
          </p>
        ) : null}
        {canEdit ? (
          <div className="mt-2 flex flex-wrap gap-2">
            {image.role !== "product_main" && image.role !== "receiving_proof" ? (
              <form action={mainAction}>
                <input type="hidden" name="image_id" value={image.id} />
                <input type="hidden" name="product_id" value={productId} />
                <Pending label="Ana görsel yap" pendingLabel="…" />
              </form>
            ) : null}
            <form action={delAction}>
              <input type="hidden" name="image_id" value={image.id} />
              <input type="hidden" name="product_id" value={productId} />
              <Pending label="Kaldır" pendingLabel="…" variant="ghost" />
            </form>
          </div>
        ) : null}
        <FormMessage state={mainState.error ? mainState : delState} />
      </div>
    </li>
  );
}

export function ImageManager({
  productId,
  images,
  variants,
  canEdit,
}: {
  productId: string;
  images: ProductImage[];
  variants: VariantRow[];
  canEdit: boolean;
}) {
  const [state, formAction] = useActionState(uploadImageAction, IDLE);
  const [role, setRole] = useState<"product_main" | "product_gallery" | "variant" | "label_tag">(
    images.some((i) => i.role === "product_main") ? "product_gallery" : "product_main",
  );

  const variantLabel = (id: string | null) => {
    if (!id) return null;
    const v = variants.find((x) => x.id === id);
    return v ? v.options.map((o) => o.value).join(" / ") || v.sku : null;
  };

  return (
    <div className="space-y-4">
      {images.length === 0 ? (
        <p className="text-sm text-text-muted">
          Bu ürünün görseli yok. Bir ana görsel eklemek listeyi ve etiket işlerini kolaylaştırır; zorunlu
          değildir.
        </p>
      ) : (
        <ul className="grid gap-2 sm:grid-cols-2">
          {images.map((image) => (
            <ImageCard key={image.id} image={image} productId={productId} variantLabel={variantLabel(image.variant_id)} canEdit={canEdit} />
          ))}
        </ul>
      )}

      {canEdit ? (
        <form action={formAction} className="space-y-3 rounded border border-border bg-background/60 p-4" encType="multipart/form-data">
          <input type="hidden" name="product_id" value={productId} />
          <div className="grid gap-3 sm:grid-cols-3">
            <div className="space-y-1.5">
              <Label htmlFor="image-role">Tür</Label>
              <Select id="image-role" name="role" value={role} onChange={(e) => setRole(e.target.value as typeof role)}>
                <option value="product_main">{IMAGE_ROLE_LABELS.product_main}</option>
                <option value="product_gallery">{IMAGE_ROLE_LABELS.product_gallery}</option>
                <option value="variant">{IMAGE_ROLE_LABELS.variant}</option>
                <option value="label_tag">{IMAGE_ROLE_LABELS.label_tag}</option>
              </Select>
            </div>
            {role === "variant" ? (
              <div className="space-y-1.5">
                <Label htmlFor="image-variant">Renk / beden</Label>
                <Select id="image-variant" name="variant_id" defaultValue="">
                  <option value="">Seçin</option>
                  {variants.map((v) => (
                    <option key={v.id} value={v.id}>
                      {v.options.map((o) => o.value).join(" / ") || v.sku}
                    </option>
                  ))}
                </Select>
              </div>
            ) : null}
            <div className={role === "variant" ? "space-y-1.5" : "space-y-1.5 sm:col-span-2"}>
              <Label htmlFor="image-file">Dosya</Label>
              <input
                id="image-file"
                name="file"
                type="file"
                accept="image/jpeg,image/png,image/webp"
                capture={role === "label_tag" ? "environment" : undefined}
                required
                className="block w-full text-xs text-text-secondary file:mr-3 file:min-h-9 file:rounded file:border file:border-border-strong file:bg-surface file:px-3 file:text-xs file:font-medium file:text-text-primary hover:file:bg-surface-muted"
              />
              <p className="text-2xs text-text-muted">JPEG, PNG veya WebP; en fazla 5 MB.</p>
            </div>
          </div>
          <FormMessage state={state} />
          <Pending label="Yükle" pendingLabel="Yükleniyor…" variant="solid" />
        </form>
      ) : null}
    </div>
  );
}
