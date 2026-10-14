import type { Context, Hono } from "hono";
import { z } from "zod";
import { apiError } from "./errors.js";
import type { Upstream } from "./upstream.js";

type Env = { Variables: { requestId: string } };
interface RouteTools {
  up: () => Upstream;
  bearer: (c: Context<Env>) => string;
  parseJson: <T extends z.ZodType>(c: Context<Env>, schema: T) => Promise<z.infer<T>>;
  pathUuid: (c: Context<Env>, name: string) => string;
}
const text = (min: number, max: number) => z.string().trim().refine(v => [...v].length >= min && [...v].length <= max);
// Database repeats this validation; URL strings are stored, never fetched by the gateway.
const publicHttps = z.string().max(2048).refine(value => {
  if (/[\u0000-\u001f\u007f]/.test(value)) return false;
  if (!/^https:\/\/([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}(\/[^\s\\]*)?$/.test(value)) return false;
  try {
    const url = new URL(value);
    return !/(^|\.)(localhost|local|internal|invalid|example|test)$/.test(url.hostname);
  } catch { return false; }
});
const metadata = z.strictObject({
  version: z.number().int().min(1).max(2_147_483_646), reason: text(5, 400),
  description: text(0, 2000).optional(), address: text(2, 300).nullish(),
  latitude: z.number().min(-90).max(90).nullish(), longitude: z.number().min(-180).max(180).nullish(),
  photo_urls: z.array(publicHttps).max(12).optional(), amenities: z.array(text(2, 60)).max(24).optional(),
  contact_phone: z.string().min(5).max(32).regex(/^[+0-9 ()-]+$/).nullish(),
  website_url: publicHttps.nullish(), booking_url: publicHttps.nullish(), booking_verified: z.boolean().optional(),
}).refine(value => {
  const lat = Object.hasOwn(value, "latitude"), lon = Object.hasOwn(value, "longitude");
  if (lat !== lon || lat && (value.latitude === null) !== (value.longitude === null)) return false;
  if (Object.hasOwn(value, "booking_url")) return value.booking_url === null || value.booking_verified === true;
  return value.booking_verified === undefined;
});
const court = z.strictObject({
  version: z.number().int().min(0).max(2_147_483_646), name: text(2, 80), indoor: z.boolean(),
  surface: text(0, 80), description: text(0, 600), is_active: z.boolean(), reason: text(5, 400),
});
function clubId(c: Context<Env>): number {
  const value = c.req.param("id");
  if (!value || !/^[1-9]\d*$/.test(value) || !Number.isSafeInteger(Number(value))) throw apiError("invalid_request");
  return Number(value);
}
function eventQuery(c: Context<Env>): Record<string, unknown> {
  const raw: Record<string, string> = {};
  for (const [key, values] of Object.entries(c.req.queries())) {
    if (values.length !== 1) throw apiError("invalid_request");
    raw[key] = values[0]!;
  }
  const int = (max: number) => z.string().regex(/^\d+$/).transform(Number).pipe(z.number().int().min(0).max(max));
  const parsed = z.strictObject({kind:z.enum(["training","tournament"]).optional(),
    scope:z.enum(["upcoming","mine"]).default("upcoming"),limit:int(50).pipe(z.number().min(1)).default(30),
    offset:int(1000).default(0)}).safeParse(raw);
  if (!parsed.success) throw apiError("invalid_request");
  return parsed.data;
}
export function registerClubsRoutes(app: Hono<Env>, {up,bearer,parseJson,pathUuid}: RouteTools): void {
  app.get("/v1/clubs/:id", async c => c.json(await up().rpc("club_detail", {p_club:clubId(c)}, bearer(c))));
  app.get("/v1/clubs/:id/events", async c => {
    const token = bearer(c), id = clubId(c), params = eventQuery(c);
    // Existing event authorization, pagination and consent apply; no client-side city filtering.
    return c.json(await up().rpc("events_catalog", {p:{...params,club_id:id}}, token));
  });
  app.patch("/v1/admin/clubs/:id", async c => {
    const token = bearer(c), id = clubId(c), p = await parseJson(c,metadata);
    return c.json(await up().rpc("admin_club_update",{p_club:id,p},token));
  });
  app.put("/v1/admin/clubs/:id/courts/:court", async c => {
    const token = bearer(c), id = clubId(c), p_court = pathUuid(c,"court"), p = await parseJson(c,court);
    return c.json(await up().rpc("admin_court_put",{p_club:id,p_court,p},token));
  });
}
