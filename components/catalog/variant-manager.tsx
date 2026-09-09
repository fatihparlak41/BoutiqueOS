"use client";

import { useActionState, useState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { FormMessage } from "@/components/catalog/form-message";
import { StatusPill } from "@/components/catalog/status-pill";
import { BarcodePanel } from "@/components/catalog/barcode-panel";
import { formatPrice, suggestSku } from "@/lib/catalog/format";
import { VARIANT_STATUS_LABELS, type ProductOption, type VariantRow } from "@/lib/catalog/model";
import { IDLE } from "@/lib/catalog/action-state";
import { createVariantAction, updateVariantAction } from "@/app/app/urunler/actions";

/**
 * Variants are the sellable SKUs. Their option combination is fixed at creation because
 * rpc_create_variant writes the variant and its option rows in one transaction and the
 * database rejects a duplicate combination through uix_variant_active_fingerprint. The UI
 * never pre-checks for duplicates — it reports what the database decided.
 */

function moneyValue(value: number): string {
  return value.toFixed(2).replace(".", ",");
}

function SubmitButton({
  label,
  pendingLabel,
  variant = "solid",
}: {
  label: string;
  pendingLabel: string;
  variant?: "solid" | "outline" | "ghost";
}) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {pending ? pendingLabel : label}
    </Button>
  );
}

function AddVariantForm({
  productId,
  skuPrefix,
  options,
}: {
  productId: string;
  skuPrefix: string;
  options: ProductOption[];
}) {
  const [state, formAction] = useActionState(createVariantAction, IDLE);
  const [selection, setSelection] = useState<Record<string, string>>({});
  const [sku, setSku] = useState("");
  const [skuEdited, setSkuEdited] = useState(false);

  const chosenValueIds = Object.values(selection).filter(Boolean);

  function handleOptionChange(optionId: string, valueId: string) {
    const next = { ...selection, [optionId]: valueId };
    setSelection(next);

    if (!skuEdited) {
      const labels = options
        .filter((option) => next[option.id])
        .map((option) => option.values.find((value) => value.id === next[option.id])?.value ?? "")
        .filter(Boolean);
      setSku(suggestSku(skuPrefix, labels));
    }
  }

  return (
    <form action={formAction} className="space-y-4 border border-line bg-panel/40 p-4">
      <h4 className="text-xs font-medium text-ink-70">Varyant ekle</h4>

      <input type="hidden" name="product_id" value={productId} />
      {chosenValueIds.map((valueId) => (
        <input key={valueId} type="hidden" name="option_value_ids" value={valueId} />
      ))}

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {options.map((option) => (
          <div key={option.id} className="space-y-1.5">
            <Label htmlFor={`option-${option.id}`}>{option.name}</Label>
            <Select
              id={`option-${option.id}`}
              value={selection[option.id] ?? ""}
              onChange={(event) => handleOptionChange(option.id, event.target.value)}
              className="h-9"
            >
              <option value="">Seçilmedi</option>
              {option.values.map((value) => (
                <option key={value.id} value={value.id}>
                  {value.value}
                </option>
              ))}
            </Select>
          </div>
        ))}
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="new-variant-sku">SKU</Label>
          <Input
            id="new-variant-sku"
            name="sku"
            required
            maxLength={64}
            spellCheck={false}
            value={sku}
            onChange={(event) => {
              setSku(event.target.value);
              setSkuEdited(true);
            }}
            placeholder="Seçenekleri seçince önerilir"
            className="h-9"
          />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="new-variant-price">Varyant fiyatı</Label>
          <Input
            id="new-variant-price"
            name="sale_price_override"
            inputMode="decimal"
            placeholder="Boş bırakılırsa ürün fiyatı"
            className="h-9"
          />
        </div>
      </div>

      <FormMessage state={state} successText="Varyant eklendi." />

      <SubmitButton label="Varyant ekle" pendingLabel="Ekleniyor…" />
    </form>
  );
}

function VariantRowItem({
  productId,
  variant,
  defaultPrice,
  canEdit,
  canManageBarcodes,
}: {
  productId: string;
  variant: VariantRow;
  defaultPrice: number;
  canEdit: boolean;
  canManageBarcodes: boolean;
}) {
  const [state, formAction] = useActionState(updateVariantAction, IDLE);
  const [open, setOpen] = useState(false);

  const effectivePrice = variant.sale_price_override ?? defaultPrice;
  const primary = variant.barcodes.find((barcode) => barcode.is_primary);

  return (
    <>
      <tr className="align-top">
        <td className="py-2.5 pr-4">
          <span className="font-medium" data-numeric>
            {variant.sku}
          </span>
        </td>
        <td className="py-2.5 pr-4 text-ink-70">
          {variant.options.length === 0
            ? "Seçeneksiz"
            : variant.options.map((pair) => `${pair.option_name}: ${pair.value}`).join(" · ")}
        </td>
        <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
          {formatPrice(effectivePrice)}
          {variant.sale_price_override === null ? (
            <span className="ml-1 text-2xs text-muted">(ürün)</span>
          ) : null}
        </td>
        <td className="py-2.5 pr-4">
          {primary ? (
            <span data-numeric className="text-xs">
              {primary.barcode}
            </span>
          ) : (
            <span className="text-2xs text-muted">yok</span>
          )}
          {variant.barcodes.length > 1 ? (
            <span className="ml-1 text-2xs text-muted">+{variant.barcodes.length - 1}</span>
          ) : null}
        </td>
        <td className="py-2.5 pr-4">
          <StatusPill status={variant.status} />
        </td>
        <td className="py-2.5 text-right">
          <Button
            type="button"
            size="sm"
            variant="ghost"
            aria-expanded={open}
            onClick={() => setOpen((value) => !value)}
          >
            {open ? "Kapat" : "Aç"}
          </Button>
        </td>
      </tr>

      {open ? (
        <tr>
          <td colSpan={6} className="border-t border-line bg-panel/30 px-3 py-4">
            <div className="grid gap-6 lg:grid-cols-2">
              <div className="space-y-3">
                <h5 className="text-xs font-medium text-ink-70">Varyant bilgileri</h5>
                {canEdit ? (
                  <form action={formAction} className="space-y-3">
                    <input type="hidden" name="variant_id" value={variant.id} />
                    <input type="hidden" name="product_id" value={productId} />

                    <div className="grid gap-3 sm:grid-cols-2">
                      <div className="space-y-1.5">
                        <Label htmlFor={`sku-${variant.id}`}>SKU</Label>
                        <Input
                          id={`sku-${variant.id}`}
                          name="sku"
                          defaultValue={variant.sku}
                          required
                          maxLength={64}
                          spellCheck={false}
                          className="h-9"
                        />
                      </div>
                      <div className="space-y-1.5">
                        <Label htmlFor={`price-${variant.id}`}>Varyant fiyatı</Label>
                        <Input
                          id={`price-${variant.id}`}
                          name="sale_price_override"
                          inputMode="decimal"
                          defaultValue={
                            variant.sale_price_override === null
                              ? ""
                              : moneyValue(variant.sale_price_override)
                          }
                          placeholder="Boş bırakılırsa ürün fiyatı"
                          className="h-9"
                        />
                      </div>
                      <div className="space-y-1.5">
                        <Label htmlFor={`status-${variant.id}`}>Durum</Label>
                        <Select
                          id={`status-${variant.id}`}
                          name="status"
                          defaultValue={variant.status}
                          className="h-9"
                        >
                          {Object.entries(VARIANT_STATUS_LABELS).map(([value, label]) => (
                            <option key={value} value={value}>
                              {label}
                            </option>
                          ))}
                        </Select>
                      </div>
                    </div>

                    <FormMessage state={state} successText="Varyant güncellendi." />
                    <SubmitButton label="Kaydet" pendingLabel="Kaydediliyor…" variant="outline" />
                  </form>
                ) : (
                  <p className="text-xs text-muted">Varyant düzenlemek için yönetici yetkisi gerekir.</p>
                )}

                <p className="text-2xs text-muted">
                  Seçenek kombinasyonu oluşturulduktan sonra değiştirilmez. Farklı bir kombinasyon
                  gerekiyorsa bu varyantı arşivleyip yenisini ekleyin.
                </p>
              </div>

              <BarcodePanel productId={productId} variant={variant} canManage={canManageBarcodes} />
            </div>
          </td>
        </tr>
      ) : null}
    </>
  );
}

export function VariantManager({
  productId,
  skuPrefix,
  defaultPrice,
  options,
  variants,
  canEdit,
  canManageBarcodes,
}: {
  productId: string;
  skuPrefix: string;
  defaultPrice: number;
  options: ProductOption[];
  variants: VariantRow[];
  canEdit: boolean;
  canManageBarcodes: boolean;
}) {
  return (
    <section className="space-y-4">
      <div>
        <h3 className="text-sm font-medium tracking-tightish">Varyantlar</h3>
        <p className="mt-1 text-xs text-muted">
          Satılabilir birimler. Stok miktarı burada tutulmaz — mal kabul ve stok hareketleriyle gelir.
        </p>
      </div>

      {variants.length === 0 ? (
        <p className="border border-dashed border-line-strong px-4 py-8 text-center text-xs text-muted">
          Henüz varyant yok. Aşağıdan ilk varyantı ekleyin.
        </p>
      ) : (
        <div className="relative overflow-x-auto">
          <table className="w-full min-w-[46rem] border-collapse text-sm">
            <thead>
              <tr className="border-y border-line text-left text-xs text-muted">
                <th scope="col" className="py-2 pr-4 font-medium">SKU</th>
                <th scope="col" className="py-2 pr-4 font-medium">Seçenekler</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Fiyat</th>
                <th scope="col" className="py-2 pr-4 font-medium">Birincil barkod</th>
                <th scope="col" className="py-2 pr-4 font-medium">Durum</th>
                <th scope="col" className="py-2 text-right font-medium">
                  <span className="sr-only">Ayrıntı</span>
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {variants.map((variant) => (
                <VariantRowItem
                  key={variant.id}
                  productId={productId}
                  variant={variant}
                  defaultPrice={defaultPrice}
                  canEdit={canEdit}
                  canManageBarcodes={canManageBarcodes}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}

      {canEdit ? (
        options.length === 0 ? (
          <p className="text-xs text-muted">
            Varyant eklemek için önce en az bir seçenek tanımlayın.
          </p>
        ) : (
          <AddVariantForm productId={productId} skuPrefix={skuPrefix} options={options} />
        )
      ) : null}
    </section>
  );
}
