import { suggestSku } from "@/lib/catalog/format";
import type { NamedRef, OptionKind, ProductStatus } from "@/lib/catalog/model";

/**
 * Vocabulary of the physical catalogue intake (/app/urunler/katalog-ekle), shared by the
 * client wizard and its server functions. No data access here.
 *
 * The intake creates the product master only: product, options, variants, label
 * barcodes, photos. It carries no quantity, no cost and no receipt link on purpose —
 * stock arrives later through goods receipts and counts.
 */

export type Result<T> = { ok: true; data: T } | { ok: false; error: string };

/** Fashion categories offered as *suggestions* when the business has no such category yet. Tenant data, never an enum. */
export const CATEGORY_SUGGESTIONS = [
  "Elbise", "Üst", "Crop", "Gömlek", "Bluz", "Tişört", "Pantolon", "Şort", "Etek",
  "Takım", "Ceket", "Mont", "Triko", "Bikini", "Mayo", "Aksesuar",
] as const;

/** One physically confirmed value of an option, as the wizard carries it. */
export type IntakeValue = {
  option_id: string;
  option_kind: OptionKind;
  value_id: string;
  value: string;
  code: string | null;
  color_hex: string | null;
  sort_order: number;
};

/** One row of the intake matrix: a combination, its SKU and the barcodes read off the label. */
export type IntakeCombo = {
  key: string;
  values: IntakeValue[];
  sku: string;
  /** Exactly what is printed; never reformatted. Empty strings are dropped before saving. */
  barcodes: string[];
  enabled: boolean;
  /** An active variant with this combination already exists on the product. */
  exists: boolean;
};

export type IntakeIdentity = {
  name: string;
  style_code: string;
  sku_prefix: string;
  category_id: string;
  brand_id: string;
  /** Turkish decimal input ("1250,00"); empty means "not set", stored as 0. */
  price: string;
};

export type ProductSummary = {
  id: string;
  name: string;
  style_code: string | null;
  sku_prefix: string;
  status: ProductStatus;
  category: NamedRef | null;
  variant_count: number;
};

export type DuplicateReport = {
  /** Same model / style code, character for character (case-insensitive). */
  style_matches: ProductSummary[];
  /** Same name after normalisation (case, spacing, punctuation) or one starts the other. */
  name_matches: ProductSummary[];
};

/** Who already owns a barcode the person typed — shown in plain words, linked to the product. */
export type KnownBarcode = { product_id: string; product_name: string; label: string };

export type OnboardVariantResult = { sku: string; variant_id: string; created: boolean; barcodes_added: number };
export type OnboardResult = { product_id: string; variants: OnboardVariantResult[] };

/** Payload of rpc_onboard_product / rpc_onboard_variants: one entry per enabled combination. */
export type OnboardCombo = { sku: string; option_value_ids: string[]; barcodes: string[] };

/**
 * Deterministic name normalisation for duplicate warnings: Turkish lower-case, one
 * space between words, letters and digits only. "Keten  Crop-Bluz" ≡ "keten crop bluz".
 * No fuzzy matching, no scoring.
 */
export function normalizeName(name: string): string {
  return name
    .toLocaleLowerCase("tr-TR")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** SKU prefix proposal: the style code when the label has one, otherwise the name. Always editable. */
export function suggestPrefix(styleCode: string, name: string): string {
  const base = styleCode.trim() || name.trim().split(/\s+/).slice(0, 3).join(" ");
  return suggestSku(base, []).slice(0, 32);
}

export function suggestComboSku(prefix: string, values: IntakeValue[]): string {
  return suggestSku(prefix, values.map((v) => v.code ?? v.value));
}

export function comboLabel(values: IntakeValue[]): string {
  return values.map((v) => v.value).join(" / ") || "Tek seçenek";
}

/** The fingerprint the database uses for "this combination already exists". */
export function comboFingerprint(values: IntakeValue[]): string {
  return values.map((v) => `${v.option_id}:${v.value_id}`).sort().join("|");
}

export function isEan13(code: string): boolean {
  return /^\d{13}$/.test(code);
}

/** Turkish → ASCII slug for category rows: "Dış Giyim" → "dis-giyim". */
export function slugify(name: string): string {
  return name
    .toLocaleLowerCase("tr-TR")
    .replace(/ı/g, "i").replace(/ş/g, "s").replace(/ğ/g, "g").replace(/ü/g, "u").replace(/ö/g, "o").replace(/ç/g, "c")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
}
