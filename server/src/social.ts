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

const uuid = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i).transform((v) => v.toLowerCase());
const id = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
const text = (min: number, max: number) => z.string().trim().refine((v) => [...v].length >= min && [...v].length <= max);
const integerQuery = (min: number, max: number) => z.string().regex(/^\d+$/).transform(Number).pipe(z.number().int().min(min).max(max));
const pagination = { limit: integerQuery(1, 50).default(30), offset: integerQuery(0, 1000).default(0) };
const paged = z.strictObject(pagination);
const booleanQuery = z.enum(["true", "false"]).transform((v) => v === "true");
const createConversation = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("direct"), player_id: uuid, client_id: uuid.optional() }),
  z.strictObject({
    kind: z.literal("group"), title: text(2, 80), description: text(0, 500).nullish(),
    visibility: z.enum(["public", "private"]).optional(), player_ids: z.array(uuid).max(30).optional(),
    city_id: id.nullish(), club_id: id.nullish(), client_id: uuid.optional(),
  }).refine((v) => !v.player_ids || new Set(v.player_ids).size === v.player_ids.length),
  z.strictObject({ kind: z.literal("game"), game_id: uuid, client_id: uuid.optional() }),
]);
const post = z.strictObject({
  body: text(1, 4000), visibility: z.enum(["public", "friends"]).optional(),
  group_id: uuid.nullish(), club_id: id.nullish(), client_id: uuid.optional(),
});
const report = z.strictObject({
  target_type: z.enum(["player", "message", "post", "comment"]), target_id: z.string().max(64),
  reason: z.enum(["spam", "harassment", "inappropriate", "other"]), detail: text(0, 500).nullish(),
}).refine((v) => v.target_type === "message"
  ? /^\d+$/.test(v.target_id) && Number.isSafeInteger(Number(v.target_id)) && Number(v.target_id) > 0
  : uuid.safeParse(v.target_id).success);

/** Bounds list queries before invoking RPCs, including repeated query parameters. */
function query<T extends z.ZodType>(c: Context<Env>, schema: T): z.infer<T> {
  const values: Record<string, string> = {};
  for (const [key, items] of Object.entries(c.req.queries())) {
    if (items.length !== 1) throw apiError("invalid_request");
    values[key] = items[0]!;
  }
  const result = schema.safeParse(values);
  if (!result.success) throw apiError("invalid_request");
  return result.data;
}

function withClientId<T extends { client_id?: string }>(body: T, key: string): T & { client_id: string } {
  if (body.client_id !== undefined && body.client_id !== key) throw apiError("invalid_request");
  return { ...body, client_id: key };
}

/** Social authorization remains in session-aware database RPCs, never in client-supplied user IDs. */
export function registerSocialRoutes(app: Hono<Env>, { up, bearer, parseJson, pathUuid, idempotencyKey }: RouteTools): void {
  app.get("/v1/social/settings", async (c) => c.json(await up().rpc("social_settings", {}, bearer(c))));
  app.patch("/v1/social/settings", async (c) => {
    const token = bearer(c);
    const p = await parseJson(c, z.strictObject({
      messages_from: z.enum(["friends", "everyone", "nobody"]).optional(),
      notify_messages: z.boolean().optional(), notify_activity: z.boolean().optional(),
    }).refine((v) => Object.keys(v).length > 0));
    return c.json(await up().rpc("update_social_settings", { p }, token));
  });
  app.get("/v1/social/blocks", async (c) => c.json(await up().rpc("blocked_players", {}, bearer(c))));
  app.get("/v1/social/follows", async (c) => c.json(await up().rpc("following_players", {}, bearer(c))));
  for (const [path, add, remove] of [
    ["blocks", "block_player", "unblock_player"], ["follows", "follow_player", "unfollow_player"],
  ] as const) {
    app.put(`/v1/social/${path}/:id`, async (c) => {
      const token = bearer(c);
      return c.json(await up().rpc(add, { p_player: pathUuid(c, "id") }, token));
    });
    app.delete(`/v1/social/${path}/:id`, async (c) => {
      const token = bearer(c);
      return c.json(await up().rpc(remove, { p_player: pathUuid(c, "id") }, token));
    });
  }
  app.post("/v1/social/reports", async (c) => {
    const token = bearer(c);
    const key = idempotencyKey(c);
    const p = await parseJson(c, report);
    return c.json(await up().rpc("report_content", { p, p_client_id: key }, token), 201);
  });
  app.get("/v1/conversations", async (c) => {
    const token = bearer(c);
    return c.json(await up().rpc("conversations", { p: query(c, paged) }, token));
  });
  app.post("/v1/conversations", async (c) => {
    const token = bearer(c);
    const key = idempotencyKey(c);
    const p = withClientId(await parseJson(c, createConversation), key);
    return c.json(await up().rpc("create_conversation", { p }, token), 201);
  });
  app.get("/v1/conversations/:id", async (c) => {
    const token = bearer(c);
    return c.json(await up().rpc("conversation", { p_conversation: pathUuid(c, "id") }, token));
  });
  app.post("/v1/conversations/:id/members", async (c) => {
    const token = bearer(c);
    const conversation = pathUuid(c, "id");
    const body = await parseJson(c, z.strictObject({ player_id: uuid, action: z.enum(["add", "remove", "transfer_owner"]) }));
    return c.json(await up().rpc("conversation_member_action", {
      p_conversation: conversation, p_player: body.player_id, p_action: body.action,
    }, token));
  });
  for (const action of ["join", "leave"] as const) {
    app.post(`/v1/conversations/:id/${action}`, async (c) => {
      const token = bearer(c);
      return c.json(await up().rpc("conversation_member_action", {
        p_conversation: pathUuid(c, "id"), p_player: null, p_action: action,
      }, token));
    });
  }
  app.get("/v1/conversations/:id/messages", async (c) => {
    const token = bearer(c);
    const conversation = pathUuid(c, "id");
    const p = query(c, z.strictObject({
      limit: pagination.limit, before_id: integerQuery(1, Number.MAX_SAFE_INTEGER).optional(),
      // Zero is the exclusive cursor before message ID 1, used when the client
      // reconciles already-visible messages as well as newly delivered ones.
      after_id: integerQuery(0, Number.MAX_SAFE_INTEGER).optional(),
    }).refine((v) => v.before_id === undefined || v.after_id === undefined));
    return c.json(await up().rpc("conversation_messages", { p_conversation: conversation, p }, token));
  });
  app.post("/v1/conversations/:id/messages", async (c) => {
    const token = bearer(c);
    const conversation = pathUuid(c, "id");
    const key = idempotencyKey(c);
    const body = await parseJson(c, z.strictObject({ body: text(1, 4000) }));
    return c.json(await up().rpc("send_message", { p_conversation: conversation, p_body: body.body, p_client_id: key }, token), 201);
  });
  app.post("/v1/conversations/:id/read", async (c) => {
    const token = bearer(c);
    const conversation = pathUuid(c, "id");
    const body = await parseJson(c, z.strictObject({ message_id: id }));
    return c.json(await up().rpc("mark_conversation_read", { p_conversation: conversation, p_message: body.message_id }, token));
  });
  app.get("/v1/social/groups", async (c) => {
    const token = bearer(c);
    const p = query(c, z.strictObject({
      ...pagination, query: text(0, 80).optional(), city_id: integerQuery(1, Number.MAX_SAFE_INTEGER).optional(),
    }));
    return c.json(await up().rpc("social_groups", { p }, token));
  });
  app.get("/v1/social/feed", async (c) => {
    const token = bearer(c);
    const p = query(c, z.strictObject({ ...pagination, scope: z.enum(["all", "following"]).default("all"), mine: booleanQuery.default(false), group_id: uuid.optional(), club_id: integerQuery(1, Number.MAX_SAFE_INTEGER).optional() }));
    return c.json(await up().rpc("social_feed", { p }, token));
  });
  app.post("/v1/social/posts", async (c) => {
    const token = bearer(c);
    const key = idempotencyKey(c);
    return c.json(await up().rpc("create_post", { p: withClientId(await parseJson(c, post), key) }, token), 201);
  });
  app.get("/v1/social/posts/:id", async (c) => {
    const token = bearer(c);
    return c.json(await up().rpc("social_post", { p_post: pathUuid(c, "id") }, token));
  });
  app.delete("/v1/social/posts/:id", async (c) => {
    const token = bearer(c);
    return c.json(await up().rpc("delete_post", { p_post: pathUuid(c, "id") }, token));
  });
  app.get("/v1/social/posts/:id/comments", async (c) => {
    const token = bearer(c);
    return c.json(await up().rpc("post_comments", { p_post: pathUuid(c, "id"), p: query(c, paged) }, token));
  });
  app.post("/v1/social/posts/:id/comments", async (c) => {
    const token = bearer(c);
    const postId = pathUuid(c, "id");
    const key = idempotencyKey(c);
    const body = await parseJson(c, z.strictObject({ body: text(1, 1000) }));
    return c.json(await up().rpc("comment_on_post", { p_post: postId, p_body: body.body, p_client_id: key }, token), 201);
  });
  app.delete("/v1/social/comments/:id", async (c) => {
    const token = bearer(c);
    return c.json(await up().rpc("delete_comment", { p_comment: pathUuid(c, "id") }, token));
  });
  app.put("/v1/social/posts/:id/reaction", async (c) => {
    const token = bearer(c);
    const postId = pathUuid(c, "id");
    const body = await parseJson(c, z.strictObject({ reaction: z.enum(["like", "celebrate", "support"]).nullable() }));
    return c.json(await up().rpc("react_to_post", { p_post: postId, p_reaction: body.reaction }, token));
  });
  app.get("/v1/notifications", async (c) => {
    const token = bearer(c);
    return c.json(await up().rpc("social_notifications", { p: query(c, paged) }, token));
  });
  app.post("/v1/notifications/read", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, z.strictObject({ id: uuid.optional() }));
    return c.json(await up().rpc("read_social_notifications", { p_id: body.id ?? null }, token));
  });
  app.get("/v1/admin/reports", async (c) => {
    const token = bearer(c);
    return c.json(await up().rpc("moderation_reports", { p: query(c, paged) }, token));
  });
  app.post("/v1/admin/reports/:id", async (c) => {
    const token = bearer(c);
    const reportId = pathUuid(c, "id");
    const body = await parseJson(c, z.strictObject({ decision: z.enum(["dismiss", "hide"]) }));
    return c.json(await up().rpc("moderate_report", { p_report: reportId, p_decision: body.decision }, token));
  });
}
