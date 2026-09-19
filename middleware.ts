import type { NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase/middleware";

export async function middleware(request: NextRequest) {
  return updateSession(request);
}

export const config = {
  // /shop/* is the public storefront: no session, no redirect, no Auth round trip per request
  matcher: ["/((?!_next/static|_next/image|favicon.ico|shop/|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)"],
};
