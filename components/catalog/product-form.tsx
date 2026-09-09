"use client";

import { useActionState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { FormMessage } from "@/components/catalog/form-message";
import { PRODUCT_STATUS_LABELS, type NamedRef, type ProductDetail } from "@/lib/catalog/model";
import { IDLE, type ActionState } from "@/lib/catalog/action-state";

type ProductFormAction = (state: ActionState, formData: FormData) => Promise<ActionState>;

function SubmitButton({ label, pendingLabel }: { label: string; pendingLabel: string }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" disabled={pending}>
      {pending ? pendingLabel : label}
    </Button>
  );
}

/** Turkish keyboards type "1250,00"; the action parses both that and "1250.00". */
function moneyValue(value: number): string {
  return value.toFixed(2).replace(".", ",");
}

export function ProductForm({
  action,
  categories,
  brands,
  product,
  submitLabel,
  pendingLabel,
}: {
  action: ProductFormAction;
  categories: NamedRef[];
  brands: NamedRef[];
  product?: ProductDetail;
  submitLabel: string;
  pendingLabel: string;
}) {
  const [state, formAction] = useActionState(action, IDLE);

  return (
    <form action={formAction} className="space-y-6" noValidate>
      {product ? <input type="hidden" name="product_id" value={product.id} /> : null}

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="name">Ürün adı</Label>
          <Input
            id="name"
            name="name"
            defaultValue={product?.name ?? ""}
            required
            maxLength={200}
            autoFocus={!product}
            placeholder="Örn. Keten Crop Bluz"
          />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="sku_prefix">SKU ön eki</Label>
          <Input
            id="sku_prefix"
            name="sku_prefix"
            defaultValue={product?.sku_prefix ?? ""}
            required
            maxLength={32}
            spellCheck={false}
            placeholder="Örn. TLC-KETEN-CROP"
          />
          <p className="text-2xs text-muted">
            Varyant SKU&apos;ları bu ön ekten türetilir. İşletme içinde benzersiz olmalı.
          </p>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="status">Durum</Label>
          <Select id="status" name="status" defaultValue={product?.status ?? "draft"}>
            {Object.entries(PRODUCT_STATUS_LABELS).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </Select>
          <p className="text-2xs text-muted">Taslak ürünler satışa çıkmaz.</p>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="category_id">Kategori</Label>
          <Select id="category_id" name="category_id" defaultValue={product?.category_id ?? ""}>
            <option value="">Seçilmedi</option>
            {categories.map((category) => (
              <option key={category.id} value={category.id}>
                {category.name}
              </option>
            ))}
          </Select>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="brand_id">Marka</Label>
          <Select id="brand_id" name="brand_id" defaultValue={product?.brand_id ?? ""}>
            <option value="">Seçilmedi</option>
            {brands.map((brand) => (
              <option key={brand.id} value={brand.id}>
                {brand.name}
              </option>
            ))}
          </Select>
          {brands.length === 0 ? (
            <p className="text-2xs text-muted">
              Henüz marka tanımlı değil. Marka olmadan da ürün kaydedebilirsiniz.
            </p>
          ) : null}
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="collection">Koleksiyon</Label>
          <Input
            id="collection"
            name="collection"
            defaultValue={product?.collection ?? ""}
            maxLength={80}
            placeholder="Örn. Yaz 2026"
          />
        </div>
      </div>

      <fieldset className="space-y-4 border-t border-line pt-5">
        <legend className="sr-only">Fiyat</legend>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-1.5">
            <Label htmlFor="default_sale_price">Varsayılan satış fiyatı</Label>
            <Input
              id="default_sale_price"
              name="default_sale_price"
              inputMode="decimal"
              required
              defaultValue={product ? moneyValue(product.default_sale_price) : ""}
              placeholder="0,00"
            />
            <p className="text-2xs text-muted">
              Varyant bazında farklı fiyat gerekirse varyant satırından geçersiz kılabilirsiniz.
            </p>
          </div>

          {product ? (
            <div className="space-y-1.5">
              <span className="block text-xs font-medium text-ink-70">KDV</span>
              <p className="text-sm" data-numeric>
                %{product.tax_rate} {product.is_tax_inclusive ? "(dahil)" : "(hariç)"}
              </p>
              <p className="text-2xs text-muted">
                Vergi oranı bu ekrandan değiştirilmez; işletme vergi ayarları netleşince ele alınacak.
              </p>
            </div>
          ) : null}
        </div>
      </fieldset>

      <div className="space-y-1.5 border-t border-line pt-5">
        <Label htmlFor="description">Açıklama</Label>
        <Textarea id="description" name="description" rows={3} defaultValue={product?.description ?? ""} />
      </div>

      <FormMessage state={state} successText="Ürün bilgileri kaydedildi." />

      <div className="flex items-center gap-3">
        <SubmitButton label={submitLabel} pendingLabel={pendingLabel} />
      </div>
    </form>
  );
}
