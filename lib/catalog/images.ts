import "server-only";

import { randomUUID } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * Product image storage rules.
 *
 * Bucket `product-images` is private. Every object lives under
 * business/<business_id>/products/<product_id>/<uuid>.<ext>: the tenant segment is what
 * the storage policies read, the file name is generated here and never taken from the
 * upload, and the extension is derived from the validated MIME type, not the client's
 * file name. Reads leave the bucket only as short-lived signed URLs, and signing is itself
 * subject to the SELECT policy — a member of one business cannot sign another's file.
 */
export const IMAGE_BUCKET = "product-images";
export const IMAGE_MAX_BYTES = 5 * 1024 * 1024;
export const SIGNED_URL_TTL_SECONDS = 60 * 60;

const EXT: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };

export type ImageValidation =
  | { ok: true; mime: "image/jpeg" | "image/png" | "image/webp"; ext: string }
  | { ok: false; error: string };

export function validateImageFile(file: File | null): ImageValidation {
  if (!file || file.size === 0) return { ok: false, error: "Bir görsel seçin." };
  if (file.size > IMAGE_MAX_BYTES) return { ok: false, error: "Görsel en fazla 5 MB olabilir." };
  const mime = file.type;
  if (mime !== "image/jpeg" && mime !== "image/png" && mime !== "image/webp") {
    return { ok: false, error: "Yalnız JPEG, PNG veya WebP yüklenebilir." };
  }
  return { ok: true, mime, ext: EXT[mime] };
}

export function productImagePath(businessId: string, productId: string, ext: string): string {
  return `business/${businessId}/products/${productId}/${randomUUID()}.${ext}`;
}

/** Signs many paths in one round trip; unsignable paths come back as null. */
export async function signImagePaths(
  supabase: SupabaseClient,
  paths: string[],
): Promise<Map<string, string | null>> {
  const out = new Map<string, string | null>();
  if (paths.length === 0) return out;

  const { data, error } = await supabase.storage.from(IMAGE_BUCKET).createSignedUrls(paths, SIGNED_URL_TTL_SECONDS);
  if (error || !data) {
    for (const p of paths) out.set(p, null);
    return out;
  }
  for (const entry of data) {
    out.set(entry.path ?? "", entry.error ? null : entry.signedUrl);
  }
  for (const p of paths) if (!out.has(p)) out.set(p, null);
  return out;
}
