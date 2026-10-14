// Full 1.2.0 routes over real Supabase Auth, PostgREST and Edge account service.
// SQL is used only to advance the disposable event clock and expire a fixture
// session; domain actions and privacy assertions all cross the public API.
import { randomUUID } from "node:crypto";
import pg from "pg";
import { beforeAll, afterAll, describe, expect, it } from "vitest";

const BASE = process.env.E2E_API_URL?.replace(/\/+$/, "");
const local = (host: string) => ["127.0.0.1", "localhost", "[::1]"].includes(host);
const RUN = Boolean(BASE && process.env.E2E_MODE !== "smoke" && local(new URL(BASE).hostname));
const DATABASE = process.env.E2E_DATABASE_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
const PASSWORD = "Padel-release-2026";
const stamp = randomUUID().replaceAll("-", "").slice(0, 10);
interface Account { id: string; email: string; token: string; }
async function request(method: string, path: string, user?: Account, body?: unknown, key?: string) {
  const headers: Record<string, string> = { "x-padelid-build": "1000" };
  if (user) headers.authorization = `Bearer ${user.token}`;
  if (body !== undefined) headers["content-type"] = "application/json";
  if (key) headers["idempotency-key"] = key;
  const response = await fetch(BASE + path, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}
function ok(result: { status: number; body: any }, status = 200) {
  expect(result.status, JSON.stringify(result.body)).toBe(status);
  return result.body;
}
function denied(result: { status: number; body: any }, status: number, code: string) {
  expect(result.status, JSON.stringify(result.body)).toBe(status);
  expect(result.body.error.code).toBe(code);
}

describe.runIf(RUN)("release 1.2.0 real-session lifecycle", () => {
  const users: Account[] = [];
  const db = new pg.Client({ connectionString: DATABASE });
  let connected = false;
  beforeAll(async () => {
    const url = new URL(DATABASE);
    expect(local(url.hostname)).toBe(true);
    expect(url.port).toBe("54322");
    await db.connect(); connected = true;
    for (let index = 0; index < 4; index++) {
      const email = `release-${index}-${stamp}@padelid.test`;
      const signup = ok(await request("POST", "/v1/auth/signup", undefined, { email, password: PASSWORD }), 201);
      const user = { id: signup.session.user.id, email, token: signup.session.access_token };
      users.push(user);
      ok(await request("POST", "/v1/me/onboarding", user, {
        username: `rel_${index}_${stamp}`, display_name: ["Анна Ким", "Борис Ким", "Вера Ким", "Глеб Ким"][index], city_id: 1,
        preferred_side: "both", dominant_hand: "right",
        calibration: { experience: "1to3y", frequency: "weekly", racket: "amateur", glass: 2, net: 1, competition: 1 },
        dna_self: { serve_return: 0, defense: 0, transition_lob: 0, net_game: 0, overheads: 0, consistency_decisions: 0 },
      }));
    }
  }, 90_000);
  afterAll(async () => {
    const failures: unknown[] = [];
    try {
      for (const user of users) {
        try {
          // One fixture's old session is intentionally expired in the last test.
          const session = ok(await request("POST", "/v1/auth/login", undefined, { email: user.email, password: PASSWORD }));
          ok(await request("DELETE", "/v1/account", { ...user, token: session.access_token }, { password: PASSWORD }), 204);
        } catch (error) { failures.push(error); }
      }
    } finally { if (connected) await db.end(); }
    if (failures.length) throw new AggregateError(failures, "Release fixture cleanup failed");
  }, 90_000);

  it("keeps private group posts/messages hidden and removes block/deletion content from canonical reads", async () => {
    const [a, b, outsider] = users as [Account, Account, Account, Account];
    ok(await request("POST", `/v1/friends/${b.id}/request`, a));
    ok(await request("POST", `/v1/friends/${a.id}/respond`, b, { decision: "accepted" }));
    const key = randomUUID();
    const body = { kind: "group", title: "Закрытая группа", visibility: "private", player_ids: [b.id] };
    const group = ok(await request("POST", "/v1/conversations", a, body, key), 201);
    expect(ok(await request("POST", "/v1/conversations", a, body, key), 201).id).toBe(group.id);
    denied(await request("GET", `/v1/conversations/${group.id}`, outsider), 404, "conversation_not_found");
    const messageKey = randomUUID();
    const message = ok(await request("POST", `/v1/conversations/${group.id}/messages`, a, { body: "Планы группы" }, messageKey), 201);
    expect(ok(await request("POST", `/v1/conversations/${group.id}/messages`, a, { body: "Планы группы" }, messageKey), 201).id).toBe(message.id);
    const post = ok(await request("POST", "/v1/social/posts", a, { body: "Закрытая публикация", group_id: group.id }, randomUUID()), 201);
    denied(await request("GET", `/v1/social/posts/${post.id}`, outsider), 404, "post_not_found");
    const comment = ok(await request("POST", `/v1/social/posts/${post.id}/comments`, b, { body: "Присоединюсь" }, randomUUID()), 201);
    expect(ok(await request("GET", `/v1/social/posts/${post.id}/comments`, a)).items.some((row: any) => row.id === comment.id)).toBe(true);
    ok(await request("PUT", `/v1/social/blocks/${a.id}`, b));
    denied(await request("GET", `/v1/social/posts/${post.id}`, b), 404, "post_not_found");
    // Blocking hides the sender's messages; other group members retain their
    // membership and can still read unrelated messages in that group.
    expect(ok(await request("GET", `/v1/conversations/${group.id}/messages`, b)).items).toEqual([]);
    ok(await request("DELETE", `/v1/social/blocks/${a.id}`, b));
    ok(await request("DELETE", `/v1/social/posts/${post.id}`, a));
    denied(await request("GET", `/v1/social/posts/${post.id}`, a), 404, "post_not_found");
    expect(ok(await request("GET", `/v1/social/feed?group_id=${group.id}`, a)).items.some((row: any) => row.id === post.id)).toBe(false);
  });

  it("edits one open event, preserves enrollment and rejects stale and foreign writes", async () => {
    const [owner, member, outsider] = users as [Account, Account, Account, Account];
    const create = { kind: "tournament", format: "americano", title: "Условия турнира", description: "Начальные условия",
      starts_at: new Date(Date.now() + 86_400_000).toISOString(), duration_minutes: 90, city_id: 1,
      location: "Корт 2", capacity: 4, min_level: 0, max_level: 7, points_per_game: 32 };
    const event = ok(await request("POST", "/v1/events", owner, create, randomUUID()), 201);
    ok(await request("POST", `/v1/events/${event.id}/register`, member, {}));
    const edit = { version: event.metadata_version, title: "Новые условия турнира", description: create.description,
      starts_at: new Date(Date.now() + 172_800_000).toISOString(), duration_minutes: 120, city_id: 1,
      location: "Корт 3", club_id: null, specialization: null, price_rub: 1500 };
    denied(await request("PUT", `/v1/events/${event.id}`, outsider, edit), 403, "organizer_required");
    const updated = ok(await request("PUT", `/v1/events/${event.id}`, owner, edit));
    expect(updated.id).toBe(event.id); expect(updated.metadata_version).toBe(2);
    expect(updated.registered_count).toBe(1);
    expect(updated.registrations[0].player.id).toBe(member.id);
    expect(updated.registrations[0].status).toBe("accepted");
    expect(updated.capacity).toBe(4); expect(updated.points_per_game).toBe(32);
    const replay = ok(await request("PUT", `/v1/events/${event.id}`, owner, edit));
    expect(replay.metadata_version).toBe(2);
    denied(await request("PUT", `/v1/events/${event.id}`, owner, { ...edit, title: "Устаревшая правка" }), 409, "event_version_conflict");
    const personal = ok(await request("GET", "/v1/events?scope=mine&upcoming_only=true", member));
    expect(personal.items.some((row: any) => row.id === event.id && row.title === edit.title)).toBe(true);
    const inbox = ok(await request("GET", "/v1/notifications", member));
    expect(inbox.items.filter((row: any) => row.resource_id === event.id && row.title === "Обновлены условия события")).toHaveLength(1);
  });

  it("runs a real tournament round with four confirmations without changing player ratings", async () => {
    const owner = users[0]!;
    const payload = { kind: "tournament", format: "americano", title: "Проверка соревнования", description: "Локальный тест",
      starts_at: new Date(Date.now() + 3_600_000).toISOString(), duration_minutes: 90, city_id: 1,
      location: "Тестовый корт", capacity: 4, min_level: 0, max_level: 7, points_per_game: 32 };
    const key = randomUUID();
    const event = ok(await request("POST", "/v1/events", owner, payload, key), 201);
    expect(ok(await request("POST", "/v1/events", owner, payload, key), 201).id).toBe(event.id);
    const before = (await db.query("select player_id,mu,ranked_matches from public.player_ratings where player_id=any($1::uuid[]) order by player_id", [users.map(user => user.id)])).rows;
    for (const user of users) ok(await request("POST", `/v1/events/${event.id}/register`, user, {}));
    await db.query("update public.sports_events set starts_at=now()-interval '1 minute' where id=$1 and organizer_id=$2", [event.id, owner.id]);
    const round = ok(await request("POST", `/v1/events/${event.id}/rounds/generate`, owner, { expected_round: 0 }));
    expect(round.current_round).toBe(1); expect(round.games).toHaveLength(1);
    const game = round.games[0];
    const scored = ok(await request("PUT", `/v1/events/${event.id}/games/${game.id}/score`, owner, { version: game.version, points1: 20, points2: 12 }));
    const version = scored.games[0].version;
    for (const user of users) ok(await request("POST", `/v1/events/${event.id}/games/${game.id}/confirm`, user, { version }));
    const canonical = ok(await request("GET", `/v1/events/${event.id}`, owner));
    expect(canonical.games[0].confirmed).toBe(true);
    expect(canonical.standings).toHaveLength(4);
    const after = (await db.query("select player_id,mu,ranked_matches from public.player_ratings where player_id=any($1::uuid[]) order by player_id", [users.map(user => user.id)])).rows;
    expect(after).toEqual(before);
    denied(await request("POST", "/v1/events", owner, { ...payload, kind: "training", format: "individual", capacity: 1 }, randomUUID()), 403, "event_coach_required");
  });

  it("exposes actual club metadata while refusing non-admin writes and unconfigured push registration", async () => {
    const user = users[0]!;
    const club = ok(await request("POST", "/v1/clubs", user, { city_id: 1, name: "Клуб проверки " + stamp }), 201);
    const detail = ok(await request("GET", `/v1/clubs/${club.id}`, user));
    expect(detail.id).toBe(club.id); expect(detail.viewer.can_edit).toBe(false);
    denied(await request("PATCH", `/v1/admin/clubs/${club.id}`, user, { version: detail.metadata_version, reason: "Чужие права", description: "Подмена" }), 403, "forbidden");
    expect(ok(await request("GET", `/v1/clubs/${club.id}/events?kind=tournament`, user)).items).toEqual([]);
    const path = `/v1/me/push-devices/${randomUUID()}`;
    denied(await request("PUT", path, undefined, { device_token: "ab", enabled: true }), 401, "not_authenticated");
    denied(await request("PUT", path, user, { device_token: "ab", enabled: true }), 503, "service_unavailable");
    expect(ok(await request("DELETE", path, user)).ok).toBe(true);
  });

  it("rejects an expired real Auth session for both profile and push revocation", async () => {
    const user = users[3]!;
    await db.query("update auth.sessions set not_after=now()-interval '1 second' where user_id=$1", [user.id]);
    denied(await request("GET", "/v1/me", user), 401, "session_expired");
    denied(await request("DELETE", `/v1/me/push-devices/${randomUUID()}`, user), 401, "session_expired");
  });
});
