import { notFound } from "next/navigation";

/** Any unknown path inside a store renders the store's own 404, never the app's. */
export default function UnknownShopPath() {
  notFound();
}
