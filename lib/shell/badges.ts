import "server-only";

import { cache } from "react";
import { orderCaps } from "@/lib/orders/model";
import { listOnlineOrders } from "@/lib/orders/queries";
import type { UserRole } from "@/lib/tenant";

/**
 * Actionable counts for the navigation, keyed by href. One bounded read per request,
 * only for roles that act on the count; anything else is an empty map. Decorative
 * counters are not added here on purpose.
 */
export const navBadges = cache(async (role: UserRole): Promise<Record<string, number>> => {
  if (!orderCaps(role).canView) return {};
  try {
    const list = await listOnlineOrders("new", null, 0, 1);
    const n = list.counts?.new ?? 0;
    return n > 0 ? { "/app/online-siparisler": n } : {};
  } catch {
    return {};
  }
});
