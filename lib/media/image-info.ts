/**
 * Reads the real format and pixel size of an uploaded image from its header bytes — no
 * decoder, no dependency. Used on upload so product_images.width/height and store media
 * carry the file's true dimensions (never an invented fallback), and so a file whose
 * bytes do not match its declared MIME type is refused before it reaches storage.
 *
 * Supported: JPEG (SOF0–SOF15 except DHT/JPG/DAC), PNG (IHDR), WebP (VP8, VP8L, VP8X).
 * Returns null for anything else or a truncated / malformed header.
 */
export type ImageInfo = { mime: "image/jpeg" | "image/png" | "image/webp"; width: number; height: number };

export function readImageInfo(b: Uint8Array): ImageInfo | null {
  if (b.length < 16) return null;
  const u16be = (i: number) => (b[i] << 8) | b[i + 1];
  const u16le = (i: number) => b[i] | (b[i + 1] << 8);
  const u24le = (i: number) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
  const u32be = (i: number) => ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];
  const ok = (w: number, h: number) => w > 0 && h > 0 && w <= 30000 && h <= 30000;

  // PNG: signature, then IHDR width/height (big endian)
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 && b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a) {
    if (b.length < 24 || String.fromCharCode(b[12], b[13], b[14], b[15]) !== "IHDR") return null;
    const w = u32be(16), h = u32be(20);
    return ok(w, h) ? { mime: "image/png", width: w, height: h } : null;
  }

  // JPEG: walk the marker segments to the first start-of-frame
  if (b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) return null;
      const marker = b[i + 1];
      if (marker === 0xff) { i += 1; continue; }                       // fill byte
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { i += 2; continue; } // no length
      const len = u16be(i + 2);
      if (len < 2) return null;
      const sof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
      if (sof) {
        const h = u16be(i + 5), w = u16be(i + 7);
        return ok(w, h) ? { mime: "image/jpeg", width: w, height: h } : null;
      }
      i += 2 + len;
    }
    return null;
  }

  // WebP: RIFF....WEBP + VP8 / VP8L / VP8X chunk
  if (String.fromCharCode(b[0], b[1], b[2], b[3]) === "RIFF" && String.fromCharCode(b[8], b[9], b[10], b[11]) === "WEBP" && b.length >= 30) {
    const chunk = String.fromCharCode(b[12], b[13], b[14], b[15]);
    if (chunk === "VP8 ") {
      if (b[23] !== 0x9d || b[24] !== 0x01 || b[25] !== 0x2a) return null;
      const w = u16le(26) & 0x3fff, h = u16le(28) & 0x3fff;
      return ok(w, h) ? { mime: "image/webp", width: w, height: h } : null;
    }
    if (chunk === "VP8L") {
      if (b[20] !== 0x2f) return null;
      const bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      const w = (bits & 0x3fff) + 1, h = ((bits >>> 14) & 0x3fff) + 1;
      return ok(w, h) ? { mime: "image/webp", width: w, height: h } : null;
    }
    if (chunk === "VP8X") {
      const w = u24le(24) + 1, h = u24le(27) + 1;
      return ok(w, h) ? { mime: "image/webp", width: w, height: h } : null;
    }
  }
  return null;
}
