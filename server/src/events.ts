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
  idempotencyKey: (c: Context<Env>) => string;
}
const uuid = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i).transform(v => v.toLowerCase());
const id = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
const text = (min: number, max: number) => z.string().trim().refine(v => [...v].length >= min && [...v].length <= max);
const intQuery = (min: number, max: number) => z.string().regex(/^\d+$/).transform(Number).pipe(z.number().int().min(min).max(max));
const creation = z.strictObject({
  client_id: uuid.optional(), kind: z.enum(["training", "tournament"]),
  format: z.enum(["individual", "group", "americano", "mexicano", "king_court", "round_robin"]),
  title: text(2, 100), description: text(0, 1200), starts_at: z.iso.datetime({ offset: true }),
  duration_minutes: z.number().int().min(30).max(240), city_id: id, club_id: id.nullish(),
  location: text(2, 160), capacity: z.number().int().min(1).max(16),
  min_level: z.number().min(0).max(7), max_level: z.number().min(0).max(7),
  specialization: text(0, 160).nullish(), price_rub: z.number().int().min(0).max(100000).nullish(),
  round_count: z.number().int().min(1).max(16).optional(), points_per_game: z.number().int().min(8).max(64).optional(),
}).refine(v => v.min_level <= v.max_level && (v.kind === "training"
  ? (v.format === "individual" && v.capacity === 1) || (v.format === "group" && v.capacity >= 2)
  : [4,8,12,16].includes(v.capacity) && ["americano","mexicano","king_court","round_robin"].includes(v.format)
    && (v.format !== "americano" || [4,8].includes(v.capacity))));
const edit = z.strictObject({
  version: z.number().int().min(1), title: text(2,100), description: text(0,1200),
  starts_at: z.iso.datetime({offset:true}), duration_minutes: z.number().int().min(30).max(240),
  city_id: id, club_id: id.nullish(), location: text(2,160),
  specialization: text(0,160).nullish(), price_rub: z.number().int().min(0).max(100000).nullish(),
});
function query<T extends z.ZodType>(c: Context<Env>, schema: T): z.infer<T> {
  const values: Record<string,string> = {};
  for (const [key, items] of Object.entries(c.req.queries())) {
    if (items.length !== 1) throw apiError("invalid_request");
    values[key] = items[0]!;
  }
  const value = schema.safeParse(values);
  if (!value.success) throw apiError("invalid_request");
  return value.data;
}
export function registerEventsRoutes(app: Hono<Env>, {up,bearer,parseJson,pathUuid,idempotencyKey}: RouteTools): void {
  app.get("/v1/events", async c => {
    const token = bearer(c);
    const p = query(c,z.strictObject({kind:z.enum(["training","tournament"]).optional(),
      city_id:intQuery(1,1_000_000).optional(),club_id:intQuery(1,Number.MAX_SAFE_INTEGER).optional(),organizer_id:uuid.optional(),scope:z.enum(["upcoming","mine"]).default("upcoming"),
      upcoming_only:z.enum(["true","false"]).transform(value => value === "true").optional(),
      limit:intQuery(1,50).default(30),offset:intQuery(0,1000).default(0)}).refine(value => !value.upcoming_only || value.scope === "mine"));
    return c.json(await up().rpc("events_catalog",{p},token));
  });
  app.post("/v1/events", async c => {
    const token = bearer(c); const key = idempotencyKey(c);
    const body = await parseJson(c,creation);
    if (body.client_id !== undefined && body.client_id !== key) throw apiError("invalid_request");
    return c.json(await up().rpc("create_event",{p:{...body,client_id:key}},token),201);
  });
  app.get("/v1/events/:id", async c => c.json(await up().rpc("event_detail",{p_event:pathUuid(c,"id")},bearer(c))));
  app.put("/v1/events/:id",async c => {
    const token = bearer(c); const event = pathUuid(c,"id");
    const p = await parseJson(c,edit);
    return c.json(await up().rpc("event_update",{p_event:event,p},token));
  });
  app.post("/v1/events/:id/register",async c => {
    const token = bearer(c); const event = pathUuid(c,"id");
    const p = await parseJson(c,z.strictObject({partner_id:uuid.nullish()}));
    return c.json(await up().rpc("event_register",{p_event:event,p_partner:p.partner_id ?? null},token));
  });
  for (const action of ["leave","cancel","complete"] as const) {
    app.post(`/v1/events/:id/${action}`,async c => c.json(await up().rpc("event_manage",{
      p_event:pathUuid(c,"id"),p_action:action,p_player:null},bearer(c))));
  }
  app.post("/v1/events/:id/participants/:player/remove",async c => c.json(await up().rpc("event_manage",{
    p_event:pathUuid(c,"id"),p_action:"remove",p_player:pathUuid(c,"player")},bearer(c))));
  app.post("/v1/events/:id/rounds/generate",async c => {
    const token = bearer(c); const event = pathUuid(c,"id");
    const p = await parseJson(c,z.strictObject({expected_round:z.number().int().min(0).max(16)}));
    return c.json(await up().rpc("event_generate_round",{p_event:event,p_expected_round:p.expected_round},token));
  });
  app.put("/v1/events/:id/games/:game/score",async c => {
    const token = bearer(c); const event = pathUuid(c,"id"); const game = pathUuid(c,"game");
    const p = await parseJson(c,z.strictObject({version:z.number().int().min(1),points1:z.number().int().min(0).max(64),points2:z.number().int().min(0).max(64)}));
    return c.json(await up().rpc("event_game_score",{p_event:event,p_game:game,p},token));
  });
  app.post("/v1/events/:id/games/:game/confirm",async c => {
    const token = bearer(c); const event = pathUuid(c,"id"); const game = pathUuid(c,"game");
    const p = await parseJson(c,z.strictObject({version:z.number().int().min(1)}));
    return c.json(await up().rpc("event_game_confirm",{p_event:event,p_game:game,p_version:p.version},token));
  });
}
