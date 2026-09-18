import "server-only";

import { cache } from "react";
import { loadAppContext } from "@/lib/app-context";
import { procurementCaps, PO_LIST_LIMIT, type PoDetail, type PoList, type PoStatus, type ReceiptPoReference } from "@/lib/po/model";

/**
 * Read side of purchasing. One bounded RPC per surface: the list (with derived
 * ordered / received / remaining and, for manager+, expected totals) and the detail
 * (lines, linked receipts, timeline). The RPC authorises from the membership and omits
 * expected costs for stock_staff; the page renders what came back.
 */

export const loadPoContext = cache(async () => {
  const ctx = await loadAppContext();
  return { ...ctx, caps: procurementCaps(ctx.role) };
});

export function isPoStatus(v: string | undefined): v is PoStatus {
  return v === "draft" || v === "approved" || v === "ordered" || v === "partially_received" || v === "received" || v === "closed" || v === "cancelled";
}

export async function listPurchaseOrders(status: PoStatus | null): Promise<PoList> {
  const { supabase, businessId } = await loadPoContext();
  const { data, error } = await supabase.rpc("rpc_po_list", { p_business_id: businessId, p_status: status, p_limit: PO_LIST_LIMIT });
  if (error) throw new Error(`Siparişler okunamadı: ${error.message}`);
  return data as PoList;
}

export async function getPurchaseOrder(id: string): Promise<PoDetail | null> {
  const { supabase } = await loadPoContext();
  const { data, error } = await supabase.rpc("rpc_po_detail", { p_po_id: id });
  if (error) {
    // NOT_FOUND / FORBIDDEN read the same to the page: this document is not here for this user.
    if (/NOT_FOUND|FORBIDDEN/.test(error.message)) return null;
    throw new Error(`Sipariş okunamadı: ${error.message}`);
  }
  return data as PoDetail;
}

/** PO reference for a linked receipt (null when the receipt is not linked). */
export async function getReceiptPoReference(receiptId: string): Promise<ReceiptPoReference | null> {
  const { supabase } = await loadPoContext();
  const { data, error } = await supabase.rpc("rpc_receipt_po_reference", { p_goods_receipt_id: receiptId });
  if (error) throw new Error(`Sipariş bağlantısı okunamadı: ${error.message}`);
  return (data as ReceiptPoReference | null) ?? null;
}
