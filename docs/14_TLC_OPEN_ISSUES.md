# TLC — açık bulgular (dokunulmadı)

Bu dosya, gerçek pilot tenant'ta (Things Like Crop, `b0000000-0000-4000-8000-000000000001`)
gözlemlenen ve **açık onay olmadan değiştirilmeyecek** durumları tutar. Her madde salt-okuma
sorgularla doğrulanmıştır; hiçbiri UX sprint'inde "düzeltilmedi".

## A. İki TLC ürünü arşivlendi (2026-09-19 13:13 UTC)

| Ürün | `status` | `updated_at` |
|---|---|---|
| TEST Keten Crop Bluz `3ca92303…` | `archived` | 2026-09-19 13:13:20 UTC |
| FATİH PARLAK `c38f5cc0…` | `archived` | 2026-09-19 13:13:39 UTC |

- 15B-0 kapanış snapshot'ında (aynı gün ~12:45 UTC) her ikisi `active` idi; UX denetimi
  başladığında (13:5x UTC) `archived`. Aradaki pencerede yalnız sahip oturumu (fatihparlak1,
  Chrome) uygulamadaydı; `products.updated_at` dışında iz yok (`archiveProductAction` denetim
  satırı yazmaz — ayrı bulgu: ürün arşivleme audit'e düşmüyor).
- Eski ürün listesinde her satırda görünen küçük **"Arşiv" düğmesi** onaysız tek tıkla arşivliyordu
  (UX denetimi #9). Pass 1 bunu ⋯ menüsü + onay diyaloğuna taşıdı; **arşivlenmiş iki ürün geri
  alınmadı** — TEST Keten'in 7 sanal birimi ve gerçek satışı (S-2026-000001) hâlâ ona bağlı;
  §28 karar tablosuna göre sahip onayı gerekir.
- 20 varyant `active` kaldı; `/app/stok` arşivli ürünün varyantlarını listelemeye devam ediyor.

**Karar (2026-10-03): ikisi de arşivli kalır.** Geri alınmadılar; durum yamasıyla (C) birlikte
hiçbir TLC ürün durumu değiştirilmedi. 2026-09-19 arşivlemesi için **geriye dönük olay yazılmadı**:
`product_status_events` o değişikliği bilmez; tarihsel yokluk tarihsel yokluk olarak kalır.

## B. Arşivli üründe stok değeri tutarsızlığı

Ürün sayfası (`/app/urunler/3ca92303…`) "Uygun stok 7" ve "Stok değeri ₺0,00 · mevcut maliyet
havuzu" gösteriyor; defterde `variant_cost_pools` 5 @400 + 2 @420 = **2.840 TRY** var.
Aynı sayfa "Renk × beden 0 × 0 · seçeneksiz" ve "Stok yaşı — hiç stoklanmadı" diyor.

- Neden (kodda doğrulandı, davranış değiştirilmedi): analiz bloğu `fn_intel_facts`
  (`20260917150000`, satır 71) yalnız `p.status = 'active' AND pv.status = 'active'` varyantları
  sayar; arşivli ürünün havuzu bu yüzden 0 görünür. "Uygun stok" ise doğrudan `v_stock_available`
  okur. Ürün arşivlenince iki kaynak ayrışıyor.
- Beklenen davranış kararı gerekir: arşivli ürünün havuz değeri "Stok değeri"nde görünmeli mi
  (muhasebe gerçeği) yoksa arşiv = "satış dışı, değerleme dışı" mı?

**Karar (2026-10-03):** arşiv **satış** kararıdır, **muhasebe** kararı değildir. Arşivli ürünün
stoğu, adet kaldıkça **stok değerlemesinin parçası olarak kalır** (havuz değeri = muhasebe gerçeği;
Pass 2 okuma düzeltmesi bunu zaten gösteriyor, docs/10 §31). Arşivli ürünler normal satış
yüzeylerinden (POS, vitrin, yayın) ve yalnız-aktif çalışan moda zekâsından (`fn_intel_facts`)
**tasarım gereği hariç** kalır; bu ayrışma hata değildir, değiştirilmedi.

## C. Ürün arşivleme/geri alma iş denetim olayı — **RESOLVED (2026-10-03)**

Çözüm: `20261003100000_product_status_audit` (docs/10 §33, ADR-24). Ürün durumu artık yalnız
`rpc_product_set_status(product_id, target_status, reason)` ile değişir (owner/manager, aynı işletme,
aktif işletme, satır kilidi, mevcut yaşam döngüsü; aynı duruma istek = olaysız no-op). Her değişiklik
aynı transaction'da değişmez bir `product_status_events` satırı yazar (işletme, ürün, önceki/yeni durum,
aktör, zaman, isteğe bağlı neden). `trg_products_status_guard` doğrudan `status` UPDATE'ini reddeder
(`USE_RPC`). UI'da neden alanı eklenmedi (RPC destekler; UX kapsamı dışı). Geriye dönük olay yok.

Önceki durum (kayıt için): `archiveProductAction` yalnız `products.status` + `updated_at` yazar; kim/ne zaman/neden kaydı yok.
Öneri (ayrı bütünlük işi, UX pass'inde yapılmadı): `rpc_product_set_status(product_id, status, reason)`
+ tenant iş denetim satırı ("product archived / restored", aktör, neden); UI onay diyaloğuna isteğe bağlı
neden alanı. Genel bir audit çerçevesi acele kurulmaz.

## D. Diğer (bilgi) — operasyonel / sahip eylemi, açık

- Kasa oturumu RS-2026-000001 16.09'dan beri açık (docs/10 §28) — panelde "uzun süredir açık" uyarısı çıkıyor.
- `settings.timezone` **2026-09-19 15:00 UTC'de sahip oturumunca `Europe/Istanbul` yapıldı** (bu oturum değil).
  Not (UX pass 3, yalnız belge): `Asia/Nicosia` Kuzey Kıbrıs'ın yaz saati geçişlerini `Europe/Istanbul`'dan
  (yıl boyu UTC+3, DST yok) daha doğru modelleyebilir; karar sahibindir, hiçbir değer değiştirilmedi.
- Kasa oturumu için uygulama artık POS ekranında "Kasa oturumu 16 Eylül'den beri açık." + Detay uyarısı
  gösterir; kapatma yalnız sahibin/yöneticinin "Kasayı kapat" onayıyla (UX pass 3, docs/10 §32).
- Taslak sayım SC-2026-000001 (2026-09-19 15:10 UTC, Türkan hesabı, 0 satır) — gerçek sahip denemesi.
- Arşivli üründe "Stok değeri ₺0,00" (B) Pass 2'de okuma tarafında giderildi (docs/10 §31).
- Bilgi (2026-10-03 snapshot): sahip 2026-09-25 12:21 UTC'de **"Oversize İşleme Bluz"** (aktif) ekledi;
  TLC artık 3 ürün / 21 varyant, 1 sayım belgesi. Bu yama sırasında before/after 67 anahtar birebir aynı.
