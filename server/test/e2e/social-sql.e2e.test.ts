// Gateway + real PostgreSQL authorization/regression checks. This deliberately
// substitutes only PostgREST HTTP transport; it does not test Supabase Auth,
// deployment networking or concurrent requests. Fixtures always roll back.
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import pg from "pg";
import { createApp } from "../../src/api.js";
import type { Config } from "../../src/config.js";
import { Upstream, type FetchFn } from "../../src/upstream.js";

const ENABLED = process.env.E2E_SQL_GATEWAY === "1";
const config: Config = {
  supabaseUrl: "https://local-sql.test", supabaseKey: "fixture-only", gatewaySecret: "g".repeat(48),
  minClientBuild: 1, upstreamTimeoutMs: 2000, signupsPerHour: 5,
};

describe.runIf(ENABLED)("social gateway → disposable PostgreSQL", () => {
  const host = process.env.PGHOST ?? "/tmp";
  const database = process.env.PGDATABASE;
  const db = new pg.Client({ host, port: Number(process.env.PGPORT ?? 55432), user: process.env.PGUSER ?? "postgres", database });
  const users = Array.from({ length: 4 }, () => ({ id: randomUUID(), session: randomUUID() }));
  let connected = false;
  let storageReads = 0;
  const transport: FetchFn = async (input, init) => {
    const url = new URL(String(input));
    if (url.pathname.startsWith("/storage/")) {
      storageReads++;
      return new Response(new Uint8Array([0xff, 0xd8, 0xff]), { status: 200 });
    }
    const rpc = url.pathname.match(/^\/rest\/v1\/rpc\/([a-z_]+)$/)?.[1];
    if (!rpc) throw new Error("Unexpected fixture transport request");
    const token = new Headers(init?.headers).get("authorization")?.replace(/^Bearer /, "");
    const user = users.find((value) => value.id === token);
    if (!user) return Response.json({ code: "PGRST301", message: "JWT fixture not authenticated" }, { status: 401 });
    const args = JSON.parse(String(init?.body)) as Record<string, unknown>;
    const entries = Object.entries(args);
    if (entries.some(([key]) => !/^p(?:_[a-z_]+)?$/.test(key))) throw new Error("Unexpected RPC parameter name");
    await db.query("reset role");
    await db.query("savepoint rpc_request");
    try {
      await db.query("select set_config('request.jwt.claims',$1,true),set_config('request.jwt.claim.sub',$2,true)", [
        JSON.stringify({ sub: user.id, session_id: user.session, role: "authenticated" }), user.id,
      ]);
      await db.query("set local role authenticated");
      const result = await db.query(`select public.${rpc}(${entries.map(([key], index) => `${key}=>$${index + 1}`).join(",")}) as value`, entries.map(([, value]) => value));
      await db.query("reset role");
      await db.query("release savepoint rpc_request");
      return Response.json(result.rows[0]!.value);
    } catch (error) {
      await db.query("rollback to savepoint rpc_request");
      await db.query("reset role");
      const sql = error as { code?: string; message?: string };
      return Response.json({ code: sql.code, message: sql.message }, { status: 400 });
    }
  };
  const app = createApp(() => ({ config, upstream: new Upstream(config, transport) }));
  async function request(user: number, method: string, path: string, body?: unknown, key?: string) {
    const response = await app.request(path, {
      method, headers: {
        authorization: `Bearer ${users[user]!.id}`, ...(body === undefined ? {} : { "content-type": "application/json" }),
        ...(key ? { "idempotency-key": key } : {}),
      }, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return { status: response.status, body: response.headers.get("content-type")?.includes("application/json") ? await response.json() : null };
  }
  const ok = (result: { status: number; body: any }, status = 200) => { expect(result.status, JSON.stringify(result.body)).toBe(status); return result.body; };
  const denied = (result: { status: number; body: any }, code: string, status: number) => {
    expect(result.status, JSON.stringify(result.body)).toBe(status); expect(result.body.error.code).toBe(code);
  };

  beforeAll(async () => {
    // No hosted connection, no production-like database name, no schema reset.
    expect(host.startsWith("/") || ["localhost", "127.0.0.1", "::1"].includes(host)).toBe(true);
    expect(database).toMatch(/^padel.*(?:test|social|local|contract)/);
    await db.connect(); connected = true;
    await db.query("begin");
    for (let index = 0; index < users.length; index++) {
      const user = users[index]!;
      await db.query("insert into auth.users(id,email,encrypted_password,raw_app_meta_data) values($1,$2,extensions.crypt('Fixture-Padel7',extensions.gen_salt('bf')),$3)", [
        user.id, `gateway-${user.id}@padel.test`, JSON.stringify({ provider: "email", providers: ["email"], padelid_origin: "account-service" }),
      ]);
      await db.query("insert into auth.sessions(id,user_id) values($1,$2)", [user.session, user.id]);
      ok(await request(index, "POST", "/v1/me/onboarding", {
        username: `gw_${user.id.replaceAll("-", "").slice(0, 12)}`, display_name: ["Анна Ким", "Борис Ким", "Вера Ким", "Глеб Ким"][index],
        city_id: 1, preferred_side: "both", dominant_hand: "right",
        calibration: { experience: "1to3y", frequency: "weekly", racket: "amateur", glass: 2, net: 1, competition: 1 },
        dna_self: { serve_return: 0, defense: 0, transition_lob: 0, net_game: 0, overheads: 0, consistency_decisions: 0 },
      }));
    }
    await db.query("set constraints all immediate");
    ok(await request(0, "POST", `/v1/friends/${users[1]!.id}/request`));
    ok(await request(1, "POST", `/v1/friends/${users[0]!.id}/respond`, { decision: "accepted" }));
  });
  afterAll(async () => { if (connected) { await db.query("rollback"); await db.end(); } });

  it("rejects foreign chat access and read cursors, and handles message retries without duplicates", async () => {
    const chat = ok(await request(0, "POST", "/v1/conversations", { kind: "direct", player_id: users[1]!.id }, randomUUID()), 201);
    const key = randomUUID();
    const message = ok(await request(0, "POST", `/v1/conversations/${chat.id}/messages`, { body: "Сообщение только друзьям" }, key), 201);
    const replay = ok(await request(0, "POST", `/v1/conversations/${chat.id}/messages`, { body: "Сообщение только друзьям" }, key), 201);
    expect(replay.id).toBe(message.id);
    denied(await request(0, "POST", `/v1/conversations/${chat.id}/messages`, { body: "Подмена текста" }, key), "version_conflict", 409);
    denied(await request(2, "GET", `/v1/conversations/${chat.id}/messages`), "conversation_not_found", 404);
    denied(await request(2, "POST", `/v1/conversations/${chat.id}/messages`, { body: "Внедрение" }, randomUUID()), "conversation_not_found", 404);
    const group = ok(await request(0, "POST", "/v1/conversations", { kind: "group", title: "Закрытая группа" }, randomUUID()), 201);
    const groupMessage = ok(await request(0, "POST", `/v1/conversations/${group.id}/messages`, { body: "Другой чат" }, randomUUID()), 201);
    denied(await request(1, "POST", `/v1/conversations/${chat.id}/read`, { message_id: groupMessage.id }), "invalid_request", 400);
    expect(ok(await request(1, "GET", `/v1/conversations/${chat.id}/messages`)).items).toHaveLength(1);
    ok(await request(1, "POST", `/v1/conversations/${chat.id}/read`, { message_id: message.id }));
    expect(ok(await request(1, "GET", `/v1/conversations/${chat.id}`)).unread_count).toBe(0);
  });

  it("protects private group posts from explicit-ID filters and rejects changed creation intent on replay", async () => {
    const key = randomUUID();
    const body = { kind: "group", title: "Парная группа", description: "Первая версия", visibility: "private", player_ids: [users[1]!.id] };
    const group = ok(await request(0, "POST", "/v1/conversations", body, key), 201);
    expect(ok(await request(0, "POST", "/v1/conversations", body, key), 201).id).toBe(group.id);
    denied(await request(0, "POST", "/v1/conversations", { ...body, description: "Другой смысл" }, key), "version_conflict", 409);
    denied(await request(0, "POST", "/v1/conversations", { ...body, player_ids: [] }, key), "version_conflict", 409);
    const post = ok(await request(0, "POST", "/v1/social/posts", { body: "Закрытые планы", group_id: group.id }, randomUUID()), 201);
    denied(await request(2, "GET", `/v1/social/posts/${post.id}`), "post_not_found", 404);
    expect(ok(await request(2, "GET", `/v1/social/feed?group_id=${group.id}`)).items).toEqual([]);
    denied(await request(2, "POST", `/v1/conversations/${group.id}/members`, { player_id: users[2]!.id, action: "add" }), "conversation_owner_required", 403);
    ok(await request(0, "POST", `/v1/conversations/${group.id}/members`, { player_id: users[1]!.id, action: "remove" }));
    denied(await request(1, "GET", `/v1/social/posts/${post.id}`), "post_not_found", 404);
    // Current membership changes do not change the original create intent.
    expect(ok(await request(0, "POST", "/v1/conversations", body, key), 201).id).toBe(group.id);
  });

  it("revokes bilateral access to DM, profile, avatars, follows, posts and comments after a block", async () => {
    const chat = ok(await request(0, "POST", "/v1/conversations", { kind: "direct", player_id: users[1]!.id }, randomUUID()), 201);
    ok(await request(1, "PUT", `/v1/social/follows/${users[0]!.id}`));
    const post = ok(await request(0, "POST", "/v1/social/posts", { body: "Публичный результат" }, randomUUID()), 201);
    const otherPost = ok(await request(2, "POST", "/v1/social/posts", { body: "Общий пост" }, randomUUID()), 201);
    ok(await request(0, "POST", `/v1/social/posts/${otherPost.id}/comments`, { body: "Личный комментарий" }, randomUUID()), 201);
    const avatar = `/v1/avatars/${users[0]!.id}/abcdefgh12.jpg`;
    expect((await request(1, "GET", avatar)).status).toBe(200);
    const readsBeforeBlock = storageReads;
    ok(await request(1, "PUT", `/v1/social/blocks/${users[0]!.id}`));
    for (const [viewer, target] of [[1, 0], [0, 1]]) {
      denied(await request(viewer!, "GET", `/v1/players/${users[target!]!.id}`), "player_not_found", 404);
      denied(await request(viewer!, "GET", `/v1/conversations/${chat.id}/messages`), "conversation_not_found", 404);
    }
    denied(await request(1, "GET", avatar), "player_not_found", 404);
    expect(storageReads).toBe(readsBeforeBlock);
    denied(await request(1, "GET", `/v1/social/posts/${post.id}`), "post_not_found", 404);
    expect(ok(await request(1, "GET", "/v1/social/follows")).items).toEqual([]);
    expect(ok(await request(1, "GET", `/v1/social/posts/${otherPost.id}/comments`)).items).toEqual([]);
    const feed = ok(await request(1, "GET", "/v1/social/feed"));
    expect(feed.items.some((item: { author: { id: string } }) => item.author.id === users[0]!.id)).toBe(false);
    denied(await request(1, "POST", `/v1/admin/reports/${randomUUID()}`, { decision: "hide" }), "forbidden", 403);
  });
});
