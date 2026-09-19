// UX sprint pass 1 — static guards over the two redesigned routes (plain Node, no framework).
// They read the source and assert the product-facing invariants the sprint promised:
//   1. one primary "Ürün ekle" CTA on /app/urunler; the legacy form only behind the quiet menu
//   2. a category is never created from a tap: creation goes through the confirm dialog only
//   3. the mobile product list is cards, the table is desktop-only
//   4. no SKU / variant / matrix vocabulary reaches the person in the guided flow
//   5. the success screen exists with its three actions, and "Stok say" only navigates
//   6. archiving passes through the confirmation dialog
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p) => readFileSync(join(root, p), "utf8");
const stripComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  if (cond) { pass++; console.log(`[PASS] ${name}`); }
  else { fail++; console.log(`[FAIL] ${name}${detail ? " - " + detail : ""}`); }
}

// 1. one primary CTA
const page = read("app/app/urunler/page.tsx");
const headerBlock = page.slice(page.indexOf("<PageHeader"), page.indexOf("{barcode && hit"));
check("products header: exactly one link to the guided flow", (headerBlock.match(/href="\/app\/urunler\/katalog-ekle"/g) ?? []).length === 1);
check("products header: primary CTA is plum and says Ürün ekle", /variant="accent"[\s\S]{0,200}Ürün ekle/.test(headerBlock));
check("products header: no direct button to the legacy form", !headerBlock.includes("/app/urunler/yeni"));
const menu = read("components/catalog/advanced-add-menu.tsx");
check("legacy form reachable only as 'Gelişmiş ürün ekleme' in the quiet menu", menu.includes("/app/urunler/yeni") && menu.includes("Gelişmiş ürün ekleme"));
check("empty state: 'İlk ürününü ekle' with the guided flow", page.includes('title="İlk ürününü ekle"') && page.includes("Ürünlerini, renklerini ve bedenlerini birkaç adımda oluştur."));
check("products page: no big filter panel (FilterBar) before the list", !page.includes("FilterBar"));

// 2. category safety
const stepProduct = stripComments(read("components/catalog/intake/step-product.tsx"));
check("step 1: no suggestion chips that write (CATEGORY_SUGGESTIONS gone)", !stepProduct.includes("CATEGORY_SUGGESTIONS"));
const createCalls = (stepProduct.match(/createCategoryAction\(/g) ?? []).length;
check("step 1: createCategoryAction is called exactly once, inside confirmCreate", createCalls === 1 && /async function confirmCreate\(\)[\s\S]*?createCategoryAction\(/.test(stepProduct));
check("step 1: creation only after the ConfirmDialog", stepProduct.includes("<ConfirmDialog") && stepProduct.includes('confirmLabel="Kategoriyi oluştur"'));
check("step 1: the Combobox offers an explicit '+ Yeni kategori oluştur' row", stepProduct.includes('createLabel="Yeni kategori oluştur"'));
const actions = read("app/app/urunler/katalog-ekle/actions.ts");
check("server: near-duplicate category names are refused", actions.includes("adlı kategori zaten var"));

// 3. mobile list
const list = read("components/catalog/product-list.tsx");
check("product list: cards for phones (lg:hidden)", /<ul[^>]*lg:hidden[^>]*data-testid="product-cards"/.test(list));
check("product list: table only from lg up", /className="hidden lg:block" data-testid="product-table"/.test(list));
check("product list: secondary actions behind a ⋯ menu", list.includes('data-testid="row-menu"') && list.includes("MoreHorizontal"));

// 4. vocabulary
const flowFiles = ["components/catalog/intake/intake-wizard.tsx", "components/catalog/intake/step-product.tsx", "components/catalog/intake/step-options.tsx", "components/catalog/intake/step-barcodes.tsx", "components/catalog/intake/step-review.tsx", "components/catalog/intake/primitives.tsx"];
for (const f of flowFiles) {
  const src = stripComments(read(f));
  // user-facing strings live in JSX text and string literals; identifiers like sku_prefix are internal
  const visible = src.replace(/\b(sku_prefix|suggestComboSku|suggestPrefix|c\.sku|v\.sku|\.sku\b|sku:)/g, "");
  check(`${f}: no user-facing SKU`, !/["'>][^"'<]*\bSKU\b/.test(visible), (visible.match(/["'>][^"'<]*\bSKU\b[^"'<]*/g) ?? []).join(" | "));
  check(`${f}: no user-facing 'varyant' / 'matris'`, !/["'>][^"'<]*\b([Vv]aryant|[Mm]atris)/.test(visible), (visible.match(/["'>][^"'<]*\b([Vv]aryant|[Mm]atris)[^"'<]*/g) ?? []).join(" | "));
}
check("step 2: shop words Renkler / Bedenler", read("components/catalog/intake/step-options.tsx").includes('"Renkler" : "Bedenler"'));
check("step 2: no-option product is 'tek seçenekli ürün'", read("components/catalog/intake/step-options.tsx").includes("tek seçenekli ürün"));
check("step 3: 'Etikette barkod varsa okutabilirsin.'", read("components/catalog/intake/step-barcodes.tsx").includes("Etikette barkod varsa okutabilirsin."));
check("step 3: no editable SKU input", !/aria-label=\{`\$\{comboLabel\(combo\.values\)\} SKU`\}/.test(read("components/catalog/intake/step-barcodes.tsx")));
check("stepper: 4 labelled steps, phone shows 'Adım n / 4'", read("components/catalog/intake/primitives.tsx").includes('["Ürün", "Renk & Beden", "Barkod", "Kontrol"]') && read("components/catalog/intake/primitives.tsx").includes("Adım {step} / {total}"));

// 5. success screen
const wizard = read("components/catalog/intake/intake-wizard.tsx");
check("success: 'Ürün hazır.'", wizard.includes("Ürün hazır."));
check("success: Stok say / Yeni ürün ekle / Ürünü gör", ["Stok say", "Yeni ürün ekle", "Ürünü gör"].every((s) => wizard.includes(s)));
check("success: 'Stok say' is a link to the count workflow, no stock write", /href="\/app\/stok\/sayim"[\s\S]{0,120}Stok say/.test(wizard) && !/rpc_stock_count|rpc_post_inventory/.test(wizard));
check("save: CTA is 'Ürünü kaydet' with a double-submit guard", wizard.includes('"Ürünü kaydet"') && wizard.includes("if (submitting.current) return;"));
check("save: the backend contract is unchanged (onboardProductAction only)", wizard.includes("onboardProductAction({ identity, combos: payload })") && !wizard.includes("onboardVariantsAction"));

// 6. archive confirmation
check("archive: only from the ⋯ menu, through ConfirmDialog", list.includes('data-testid="row-archive"') && list.includes("Bu ürünü arşivlemek istiyor musun?") && list.includes("Ürün satış ekranlarından kaldırılır. Geçmiş kayıtlar korunur."));
const archiveCalls = (list.match(/archiveProductAction\(/g) ?? []).length;
check("archive: the action is called exactly once, inside confirm()", archiveCalls === 1 && /function confirm\(\)[\s\S]*?archiveProductAction\(/.test(list));
check("archive: confirm button is destructive and says Arşivle, cancel is Vazgeç", list.includes('confirmLabel={target?.status === "archived" ? "Satışa aç" : "Arşivle"}') && read("components/ui/confirm-dialog.tsx").includes('cancelLabel = "Vazgeç"'));

console.log(`\nPASS ${pass} FAIL ${fail}`);
process.exit(fail === 0 ? 0 : 1);
