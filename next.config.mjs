/**
 * Image optimisation is allowed for exactly one remote source: the public storefront
 * bucket of this project's Supabase (published product copies, store logo / hero). The
 * private product-images bucket is never optimised (it is read through signed URLs only),
 * and no other host can be proxied through /_next/image.
 */
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL ? new URL(process.env.NEXT_PUBLIC_SUPABASE_URL) : null;

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  // image uploads go through server actions (≤ 4 MB file + multipart overhead; Vercel caps bodies at 4.5 MB)
  experimental: { serverActions: { bodySizeLimit: "4.5mb" } },
  images: {
    remotePatterns: supabaseUrl
      ? [{ protocol: supabaseUrl.protocol.replace(":", ""), hostname: supabaseUrl.hostname, port: supabaseUrl.port, pathname: "/storage/v1/object/public/storefront-images/**" }]
      : [],
    formats: ["image/avif", "image/webp"],
    // published paths are content-addressed by uuid: a new upload is a new URL
    minimumCacheTTL: 2678400,
    // 828 = 390–414 @2x, 1200 = 390 @3x and the 585 px desktop hero @2x (no jump to 1440 / 1920)
    deviceSizes: [390, 640, 768, 828, 1080, 1200, 1440, 1920],
    imageSizes: [64, 96, 128, 256, 384],
  },
};

export default nextConfig;
