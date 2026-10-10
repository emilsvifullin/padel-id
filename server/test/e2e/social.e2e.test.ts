// These scenarios require a disposable local Supabase stack. Direct SQL is
// limited to local fixture ratings/time; all domain actions go through the API.
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import pg from "pg";

const BASE = process.env.E2E_API_URL?.replace(/\/+$/, "");
const MODE = process.env.E2E_MODE ?? "full";
const localHost = (host: string) => ["localhost", "127.0.0.1", "[::1]"].includes(host);
const RUN = Boolean(BASE && MODE === "full" && localHost(new URL(BASE).hostname));
const DATABASE_URL = process.env.E2E_DATABASE_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
const PASSWORD = "Padel-2026-social";
const STAMP = `${Date.now().toString(36).slice(-6)}${Math.random().toString(36).slice(2, 5)}`;

interface Account { id: string; token: string; email: string; }
interface Result { status: number; body: any; }
async function call(method: string, path: string, user?: Account, body?: unknown, key?: string): Promise<Result> {
  const headers: Record<string, string> = { "x-padelid-build": "1000" };
  if (user) headers.authorization = `Bearer ${user.token}`;
  if (key) headers["idempotency-key"] = key;
  if (body !== undefined) headers["content-type"] = "application/json";
  const res = await fetch(`${BASE}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}
function ok(res: Result, status = 200) { expect(res.status, JSON.stringify(res.body)).toBe(status); return res.body; }
function rejected(res: Result, code: string, status: number) { expect(res.status, JSON.stringify(res.body)).toBe(status); expect(res.body.error.code).toBe(code); }

function resultPayload(ids: string[], overrides: Record<string, unknown> = {}) {
  return {
    match_type: "ranked", format: "best_of_3", played_at: new Date(Date.now() - 60_000).toISOString(),
    players: ids.map((id, index) => ({ player_id: id, team: index < 2 ? 1 : 2, court_side: index % 2 ? "left" : "right" })),
    sets: [{ t1: 6, t2: 4 }, { t1: 6, t2: 3 }], ...overrides,
  };
}

describe.runIf(RUN)("local mutual friendship and future-game lifecycle", () => {
  const accounts: Account[] = [];
  const db = new pg.Client({ connectionString: DATABASE_URL });
  let connected = false;

  beforeAll(async () => {
    // Do not allow a fixture connection to a hosted database.
    expect(localHost(new URL(DATABASE_URL).hostname)).toBe(true);
    await db.connect();
    connected = true;
    for (let i = 0; i < 7; i++) {
      const email = `social-${i}-${STAMP}@padelid.test`;
      const created = ok(await call("POST", "/v1/auth/signup", undefined, { email, password: PASSWORD }), 201);
      const user = { id: created.session.user.id, token: created.session.access_token, email };
      accounts.push(user);
      ok(await call("POST", "/v1/me/onboarding", user, {
        username: `soc_${i}_${STAMP}`, display_name: ["Анна Ким", "Борис Ким", "Вера Ким", "Глеб Ким", "Дина Ким", "Ева Ким", "Жан Ким"][i],
        city_id: 1, preferred_side: "both", dominant_hand: "right", playing_since: 2022,
        calibration: { experience: "1to3y", frequency: "weekly", racket: "amateur", glass: 2, net: 1, competition: 1 },
        dna_self: { serve_return: 0, defense: 1, transition_lob: 0, net_game: -1, overheads: 0, consistency_decisions: 0 },
      }));
    }
    await db.query("update public.player_ratings set mu=3.5, peak_mu=3.5, sigma=0.25, ranked_matches=5, last_ranked_at=now() where player_id=any($1::uuid[])", [accounts.slice(1, 5).map((a) => a.id)]);
    await db.query("update public.player_ratings set sigma=0.46 where player_id=$1", [accounts[4]!.id]);
    // Reliability 69 despite ten games: still needs organizer review.
    await db.query("update public.player_ratings set mu=3.5, peak_mu=3.5, sigma=0.467, ranked_matches=10, last_ranked_at=now() where player_id=$1", [accounts[5]!.id]);
    // High confidence alone cannot make a self-calibrated beginner automatic.
    await db.query("update public.player_ratings set mu=3.5, peak_mu=3.5, sigma=0.25, ranked_matches=4, last_ranked_at=now() where player_id=$1", [accounts[6]!.id]);
  }, 90_000);

  afterAll(async () => {
    const failures: unknown[] = [];
    try {
      for (const user of accounts) {
        try {
          const removed = await call("DELETE", "/v1/account", user, { password: PASSWORD });
          expect(removed.status, JSON.stringify(removed.body)).toBe(204);
        } catch (error) {
          failures.push(error);
        }
      }
    } finally {
      if (connected) await db.end();
    }
    if (failures.length) throw new AggregateError(failures, "Local fixture cleanup failed");
  }, 90_000);

  const publish = async (patch: Record<string, unknown> = {}) => {
    const key = crypto.randomUUID();
    const body = { client_id: key, starts_at: new Date(Date.now() + 3_600_000).toISOString(), city_id: 1, club_id: null,
      location: "Центральный корт", match_type: "ranked", min_level: 3, max_level: 4, note: null, ...patch };
    const [first, retry] = await Promise.all([
      call("POST", "/v1/upcoming-matches", accounts[0], body, key),
      call("POST", "/v1/upcoming-matches", accounts[0], body, key),
    ]);
    const game = ok(first, 201);
    expect(ok(retry, 201).id).toBe(game.id);
    expect(game.participants).toHaveLength(1);
    expect(game.result_match_id).toBeNull();
    return game;
  };

  it("keeps mutual friendships symmetric, private and safe under repeated requests", async () => {
    const [a, b, outsider] = [accounts[0]!, accounts[1]!, accounts[2]!];
    const requested = await Promise.all([call("POST", `/v1/friends/${b.id}/request`, a), call("POST", `/v1/friends/${b.id}/request`, a)]);
    for (const res of requested) expect(ok(res).status).toBe("outgoing");
    expect(ok(await call("GET", "/v1/friends", a)).outgoing).toHaveLength(1);
    expect(ok(await call("GET", "/v1/friends", b)).incoming).toHaveLength(1);
    expect(ok(await call("POST", `/v1/friends/${a.id}/request`, b)).status).toBe("incoming");
    ok(await call("PATCH", "/v1/me", b, { discoverable: false }));
    const hiddenPending = ok(await call("GET", "/v1/friends", a)).outgoing[0].player;
    expect(hiddenPending.id).toBe(b.id);
    expect(hiddenPending.username).toBeNull();
    expect(hiddenPending.city).toBeNull();
    expect(hiddenPending.level).toBeNull();
    rejected(await call("GET", `/v1/players/${b.id}`, a), "player_not_found", 404);
    ok(await call("PATCH", "/v1/me", b, { discoverable: true }));
    rejected(await call("POST", `/v1/friends/${b.id}/respond`, a, { decision: "accepted" }), "friendship_not_incoming", 409);
    rejected(await call("POST", `/v1/friends/${a.id}/respond`, outsider, { decision: "accepted" }), "friendship_not_pending", 409);
    rejected(await call("POST", `/v1/friends/${a.id}/request`, a), "friendship_self", 400);
    expect(ok(await call("POST", `/v1/friends/${a.id}/respond`, b, { decision: "accepted" })).status).toBe("accepted");
    for (const [user, friend] of [[a, b], [b, a]]) {
      const list = ok(await call("GET", "/v1/friends", user));
      expect(list.accepted.map((r: any) => r.player.id)).toEqual([friend!.id]);
      expect(list.incoming).toHaveLength(0);
      expect(list.outgoing).toHaveLength(0);
      expect(JSON.stringify(list)).not.toMatch(/@padelid.test|calibration|notify_|discoverable/);
    }
    ok(await call("PATCH", "/v1/me", b, { discoverable: false }));
    ok(await call("GET", `/v1/players/${b.id}`, a));
    rejected(await call("GET", `/v1/players/${b.id}`, outsider), "player_not_found", 404);
    ok(await call("DELETE", `/v1/friends/${b.id}`, a));
    expect(ok(await call("GET", "/v1/friends", b)).accepted).toHaveLength(0);
    rejected(await call("GET", `/v1/players/${b.id}`, a), "player_not_found", 404);
    ok(await call("PATCH", "/v1/me", b, { discoverable: true }));
    ok(await call("POST", `/v1/friends/${b.id}/request`, a));
    ok(await call("DELETE", `/v1/friends/${b.id}`, a));
    expect(ok(await call("GET", "/v1/friends", b)).incoming).toHaveLength(0);
    ok(await call("POST", `/v1/friends/${b.id}/request`, a));
    ok(await call("POST", `/v1/friends/${a.id}/respond`, b, { decision: "rejected" }));
    expect(ok(await call("GET", `/v1/friends/${b.id}`, a)).status).toBe("none");
  });

  it("admits reliable players only inside the level range and sends uncertain players to their organizer", async () => {
    const game = await publish({ min_level: 3.5, max_level: 3.5 });
    const id = game.id;
    const mine = ok(await call("GET", "/v1/upcoming-matches?scope=mine", accounts[0]));
    expect(mine.items.some((m: any) => m.id === id)).toBe(true);
    const first = ok(await call("POST", `/v1/upcoming-matches/${id}/join`, accounts[1]));
    expect(first.viewer.participation).toBe("accepted");
    expect(first.participants).toHaveLength(2);
    expect(ok(await call("POST", `/v1/upcoming-matches/${id}/join`, accounts[1])).participants).toHaveLength(2);
    for (const user of [accounts[5]!, accounts[6]!]) {
      const pending = ok(await call("POST", `/v1/upcoming-matches/${id}/join`, user));
      expect(pending.viewer.participation).toBe("pending");
      expect(pending.participants).toHaveLength(2);
      expect(pending.applications.map((r: any) => r.player.id)).toEqual([user.id]);
    }
    const owner = ok(await call("GET", `/v1/upcoming-matches/${id}`, accounts[0]));
    expect(owner.applications.filter((a: any) => a.status === "pending")).toHaveLength(2);
    expect(owner.admission).toEqual({ min_reliability: 70, minimum_ranked_matches: 5 });
    const pendingHome = ok(await call("GET", "/v1/upcoming-matches?scope=mine&accepted_only=true", accounts[5]));
    expect(pendingHome.items.some((m: any) => m.id === id)).toBe(false);
    rejected(await call("POST", `/v1/upcoming-matches/${id}/requests/${accounts[5]!.id}/respond`, accounts[1], { decision: "accepted" }), "organizer_required", 403);
    const accepted = ok(await call("POST", `/v1/upcoming-matches/${id}/requests/${accounts[5]!.id}/respond`, accounts[0], { decision: "accepted" }));
    expect(accepted.participants).toHaveLength(3);
    expect(accepted.result_match_id).toBeNull();
    const acceptedHome = ok(await call("GET", "/v1/upcoming-matches?scope=mine&accepted_only=true", accounts[5]));
    expect(acceptedHome.items.some((m: any) => m.id === id)).toBe(true);
    expect(ok(await call("POST", `/v1/upcoming-matches/${id}/requests/${accounts[5]!.id}/respond`, accounts[0], { decision: "accepted" })).participants).toHaveLength(3);
    ok(await call("POST", `/v1/upcoming-matches/${id}/requests/${accounts[6]!.id}/respond`, accounts[0], { decision: "rejected" }));
    expect(ok(await call("GET", `/v1/upcoming-matches/${id}`, accounts[6])).viewer.participation).toBe("rejected");
    const threshold = await publish({ min_level: 3.5, max_level: 3.5 });
    expect(ok(await call("GET", "/v1/me", accounts[4])).rating.reliability).toBe(70);
    expect(ok(await call("POST", `/v1/upcoming-matches/${threshold.id}/join`, accounts[4])).viewer.participation).toBe("accepted");
    ok(await call("POST", `/v1/upcoming-matches/${threshold.id}/cancel`, accounts[0]));
    const outside = await publish({ min_level: 4, max_level: 5 });
    rejected(await call("POST", `/v1/upcoming-matches/${outside.id}/join`, accounts[2]), "level_out_of_range", 403);
    // Uncertainty is reviewed even outside the range rather than a beginner lockout.
    expect(ok(await call("POST", `/v1/upcoming-matches/${outside.id}/join`, accounts[6])).viewer.participation).toBe("pending");
    ok(await call("POST", `/v1/upcoming-matches/${outside.id}/cancel`, accounts[0]));
    rejected(await call("POST", `/v1/upcoming-matches/${outside.id}/join`, accounts[1]), "scheduled_match_closed", 409);
  });

  it("serializes joins and approvals at the final slot, supports leaving, and prevents unauthorized cancellation", async () => {
    const game = await publish();
    const path = `/v1/upcoming-matches/${game.id}`;
    ok(await call("POST", `${path}/join`, accounts[1]));
    ok(await call("POST", `${path}/join`, accounts[2]));
    const joins = await Promise.all([call("POST", `${path}/join`, accounts[3]), call("POST", `${path}/join`, accounts[4])]);
    expect(joins.map((r) => r.status).sort()).toEqual([200, 409]);
    expect(joins.find((r) => r.status === 409)!.body.error.code).toBe("scheduled_match_full");
    const owner = ok(await call("GET", path, accounts[0]));
    expect(owner.participants).toHaveLength(4);
    expect(owner.spots_left).toBe(0);
    expect(owner.status).toBe("full");
    const winner = owner.participants.find((p: any) => [accounts[3]!.id, accounts[4]!.id].includes(p.player.id)).player.id;
    const leaving = accounts.find((a) => a.id === winner)!;
    ok(await call("POST", `${path}/leave`, leaving));
    expect(ok(await call("POST", `${path}/leave`, leaving)).participants).toHaveLength(3);
    rejected(await call("POST", `${path}/leave`, accounts[0]), "organizer_cannot_leave", 409);
    rejected(await call("POST", `${path}/cancel`, accounts[1]), "organizer_required", 403);
    for (const user of [accounts[5]!, accounts[6]!]) ok(await call("POST", `${path}/join`, user));
    const reviews = await Promise.all([accounts[5]!, accounts[6]!].map((u) => call("POST", `${path}/requests/${u.id}/respond`, accounts[0], { decision: "accepted" })));
    expect(reviews.map((r) => r.status).sort()).toEqual([200, 409]);
    expect(ok(await call("GET", path, accounts[0])).participants).toHaveLength(4);
    ok(await call("POST", `${path}/cancel`, accounts[0]));
    expect(ok(await call("POST", `${path}/cancel`, accounts[0])).status).toBe("cancelled");
  });

  it("links exactly one authoritative played result and still requires all four confirmations", async () => {
    const game = await publish();
    const path = `/v1/upcoming-matches/${game.id}`;
    for (const user of accounts.slice(1, 4)) ok(await call("POST", `${path}/join`, user));
    const ids = accounts.slice(0, 4).map((a) => a.id);
    const payload = resultPayload(ids);
    rejected(await call("POST", `${path}/result`, accounts[0], payload, crypto.randomUUID()), "scheduled_match_not_started", 409);
    const moved = await db.query("update public.scheduled_matches set starts_at=now()-interval '2 hours' where id=$1 returning starts_at", [game.id]);
    const plannedStart = moved.rows[0].starts_at.getTime();
    rejected(await call("POST", `${path}/result`, accounts[4], payload, crypto.randomUUID()), "scheduled_match_not_found", 404);
    rejected(await call("POST", `${path}/result`, accounts[0], resultPayload([...ids.slice(0, 3), accounts[4]!.id]), crypto.randomUUID()), "scheduled_lineup_mismatch", 400);
    const before = await Promise.all(accounts.slice(0, 4).map((u) => call("GET", "/v1/me", u)));
    const key = crypto.randomUUID();
    const created = await Promise.all([call("POST", `${path}/result`, accounts[0], payload, key), call("POST", `${path}/result`, accounts[0], payload, key)]);
    const result = ok(created[0]!, 201);
    expect(ok(created[1]!, 201).id).toBe(result.id);
    expect(result.scheduled_match_id).toBe(game.id);
    expect(Date.parse(result.scheduled_starts_at)).toBe(plannedStart);
    expect(Date.parse(result.played_at)).toBeGreaterThanOrEqual(plannedStart);
    const linkedDetail = ok(await call("GET", `/v1/matches/${result.id}`, accounts[0]));
    expect(linkedDetail.scheduled_match_id).toBe(game.id);
    expect(Date.parse(linkedDetail.scheduled_starts_at)).toBe(plannedStart);
    expect(result.status).toBe("pending");
    expect(result.rating_applied).toBe(false);
    expect(ok(await call("POST", `${path}/result`, accounts[0], payload, crypto.randomUUID()), 201).id).toBe(result.id);
    rejected(await call("POST", `${path}/result`, accounts[0], { ...payload, sets: [{ t1: 6, t2: 1 }, { t1: 6, t2: 2 }] }, crypto.randomUUID()), "scheduled_result_mismatch", 409);
    rejected(await call("POST", `${path}/join`, accounts[4]), "scheduled_match_closed", 409);
    const scheduled = ok(await call("GET", path, accounts[0]));
    expect(scheduled.result_match_id).toBe(result.id);
    expect(scheduled.status).toBe("result_pending");
    rejected(await call("PUT", `/v1/matches/${result.id}`, accounts[0], {
      version: 1, match: resultPayload([...ids.slice(0, 3), accounts[4]!.id], { played_at: payload.played_at }),
    }, crypto.randomUUID()), "scheduled_lineup_mismatch", 400);
    // Score corrections remain available and reset the four confirmations.
    const corrected = ok(await call("PUT", `/v1/matches/${result.id}`, accounts[0], {
      version: 1, match: { ...payload, sets: [{ t1: 6, t2: 2 }, { t1: 6, t2: 3 }] },
    }, crypto.randomUUID()));
    expect(corrected.version).toBe(2);
    for (const user of accounts.slice(1, 3)) ok(await call("POST", `/v1/matches/${result.id}/confirm`, user, { version: 2 }));
    expect(ok(await call("GET", `/v1/matches/${result.id}`, accounts[0])).status).toBe("pending");
    const finals = await Promise.all([call("POST", `/v1/matches/${result.id}/confirm`, accounts[3], { version: 2 }), call("POST", `/v1/matches/${result.id}/confirm`, accounts[3], { version: 2 })]);
    for (const res of finals) expect(ok(res).status).toBe("confirmed");
    const after = await Promise.all(accounts.slice(0, 4).map((u) => call("GET", "/v1/me", u)));
    after.forEach((r, i) => expect(r.body.rating.ranked_matches).toBe(before[i]!.body.rating.ranked_matches + 1));
    const completed = ok(await call("GET", path, accounts[0]));
    expect(completed.status).toBe("completed");
    expect(completed.result_status).toBe("confirmed");
  });
});
