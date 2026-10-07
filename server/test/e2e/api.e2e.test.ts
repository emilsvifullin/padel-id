// End-to-end tests of the public API against a real stack.
//
//   E2E_API_URL   base URL of a running gateway (required, otherwise skipped)
//   E2E_MODE      "full" (default; local disposable stack) or "smoke"
//                 (production: creates one temporary account without a
//                 profile and deletes it, leaving no data behind)

import { describe, expect, it } from "vitest";

const BASE = process.env.E2E_API_URL?.replace(/\/+$/, "");
const MODE = process.env.E2E_MODE ?? "full";
const RUN = Boolean(BASE);
const STAMP = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;

interface Res<T = any> {
  status: number;
  body: T;
}

async function call<T = any>(method: string, path: string, opts: { token?: string; body?: unknown; headers?: Record<string, string>; raw?: BodyInit } = {}): Promise<Res<T>> {
  const headers: Record<string, string> = { "x-padelid-build": "1000", ...(opts.headers ?? {}) };
  if (opts.token) headers.authorization = `Bearer ${opts.token}`;
  let body: BodyInit | undefined = opts.raw;
  if (opts.body !== undefined) {
    headers["content-type"] = "application/json";
    body = JSON.stringify(opts.body);
  }
  const res = await fetch(`${BASE}${path}`, { method, headers, body });
  const text = await res.text();
  return { status: res.status, body: text ? (JSON.parse(text) as T) : (null as T) };
}

const PASSWORD = "Padel-2026-test";

interface Account {
  email: string;
  token: string;
  refresh: string;
  id: string;
  recoveryKey: string;
}

async function signup(tag: string): Promise<Account> {
  const email = `e2e-${tag}-${STAMP}@padelid.test`;
  const res = await call("POST", "/v1/auth/signup", { body: { email, password: PASSWORD } });
  expect(res.status, JSON.stringify(res.body)).toBe(201);
  expect(res.body.recovery_key).toMatch(/^[0-9A-Z]{5}(-[0-9A-Z]{5}){3}$/);
  return {
    email,
    token: res.body.session.access_token,
    refresh: res.body.session.refresh_token,
    id: res.body.session.user.id,
    recoveryKey: res.body.recovery_key,
  };
}

function onboardingPayload(username: string, name: string, glass = 2) {
  return {
    username,
    display_name: name,
    city_id: 1,
    preferred_side: "both",
    dominant_hand: "right",
    playing_since: 2022,
    calibration: { experience: "1to3y", frequency: "weekly", racket: "amateur", glass, net: 1, competition: 1 },
    dna_self: { serve_return: 0, defense: 1, transition_lob: 0, net_game: -1, overheads: 0, consistency_decisions: 0 },
  };
}

function lineup(ids: string[]) {
  return [
    { player_id: ids[0], team: 1, court_side: "right" },
    { player_id: ids[1], team: 1, court_side: "left" },
    { player_id: ids[2], team: 2, court_side: "right" },
    { player_id: ids[3], team: 2, court_side: "left" },
  ];
}

describe.runIf(RUN && MODE === "smoke")("production smoke", () => {
  it("serves health and rejects anonymous access", async () => {
    expect((await call("GET", "/v1/health")).status).toBe(200);
    const deep = await call("GET", "/v1/health?deep=1");
    expect(deep.body.status).toBe("ok");
    expect(deep.body.database).toBe("ok");
    const me = await call("GET", "/v1/me");
    expect(me.status).toBe(401);
  });

  it("runs the account lifecycle without leaving data", async () => {
    const a = await signup("smoke");
    let me = await call("GET", "/v1/me", { token: a.token });
    expect(me.status).toBe(200);
    expect(me.body.needs_onboarding).toBe(true);
    expect(me.body.email).toBe(a.email);
    const refreshed = await call("POST", "/v1/auth/refresh", { body: { refresh_token: a.refresh } });
    expect(refreshed.status).toBe(200);
    const login = await call("POST", "/v1/auth/login", { body: { email: a.email, password: PASSWORD } });
    expect(login.status).toBe(200);
    const cities = await call("GET", "/v1/cities", { token: login.body.access_token });
    expect(cities.body[0].name).toBe("Москва");
    const del = await call("DELETE", "/v1/account", { token: login.body.access_token, body: { password: PASSWORD } });
    expect(del.status).toBe(204);
    const again = await call("POST", "/v1/auth/login", { body: { email: a.email, password: PASSWORD } });
    expect(again.status).toBe(401);
    me = await call("GET", "/v1/me", { token: refreshed.body.access_token });
    expect([401, 403, 404]).toContain(me.status);
  });
});

describe.runIf(RUN && MODE === "full")("full API flow", () => {
  const players: Account[] = [];
  let outsider: Account;

  it("registers accounts with validation", async () => {
    const weak = await call("POST", "/v1/auth/signup", { body: { email: `weak-${STAMP}@padelid.test`, password: "12345678" } });
    expect(weak.status).toBe(400);
    expect(weak.body.error.code).toBe("weak_password");
    for (const tag of ["a", "b", "c", "d"]) players.push(await signup(tag));
    outsider = await signup("x");
    const dup = await call("POST", "/v1/auth/signup", { body: { email: players[0]!.email.toUpperCase(), password: PASSWORD } });
    expect(dup.status).toBe(409);
    expect(dup.body.error.code).toBe("email_taken");
  });

  it("signs in, refreshes and rejects wrong passwords", async () => {
    const wrong = await call("POST", "/v1/auth/login", { body: { email: players[0]!.email, password: "Wrong-pass-1" } });
    expect(wrong.status).toBe(401);
    const ok = await call("POST", "/v1/auth/login", { body: { email: players[0]!.email, password: PASSWORD } });
    expect(ok.status).toBe(200);
    const refreshed = await call("POST", "/v1/auth/refresh", { body: { refresh_token: ok.body.refresh_token } });
    expect(refreshed.status).toBe(200);
    const reused = await call("POST", "/v1/auth/refresh", { body: { refresh_token: "definitely-not-a-valid-token" } });
    expect(reused.status).toBe(401);
    expect(reused.body.error.code).toBe("session_expired");
  });

  it("completes onboarding for everyone", async () => {
    const names = ["Анна Морозова", "Борис Ким", "Вера Соколова", "Глеб Орлов", "Ёлка Посторонняя"];
    const all = [...players, outsider];
    for (let i = 0; i < all.length; i++) {
      const acc = all[i]!;
      const me = await call("GET", "/v1/me", { token: acc.token });
      expect(me.body.needs_onboarding).toBe(true);
      const check = await call("GET", `/v1/me/username-check?username=e2e_${i}_${STAMP.slice(0, 8)}`, { token: acc.token });
      expect(check.body.available).toBe(true);
      const res = await call("POST", "/v1/me/onboarding", { token: acc.token, body: onboardingPayload(`e2e_${i}_${STAMP.slice(0, 8)}`, names[i]!, i < 2 ? 3 : 1) });
      expect(res.status, JSON.stringify(res.body)).toBe(200);
      expect(res.body.needs_onboarding).toBe(false);
      expect(res.body.rating.provisional).toBe(true);
    }
    const taken = await call("PATCH", "/v1/me", { token: players[1]!.token, body: { username: `e2e_0_${STAMP.slice(0, 8)}` } });
    expect(taken.status).toBe(409);
  });

  it("creates clubs and updates the profile", async () => {
    const club = await call("POST", "/v1/clubs", { token: players[0]!.token, body: { city_id: 1, name: `Корт ${STAMP}` } });
    expect(club.status).toBe(201);
    const same = await call("POST", "/v1/clubs", { token: players[1]!.token, body: { city_id: 1, name: `  корт ${STAMP.toUpperCase()} ` } });
    expect(same.body.id).toBe(club.body.id);
    const me = await call("PATCH", "/v1/me", { token: players[0]!.token, body: { club_id: club.body.id, preferred_side: "right", bio: "Люблю играть у сетки" } });
    expect(me.body.profile.club.name).toBe(`Корт ${STAMP}`);
  });

  let matchId = "";

  it("creates a ranked match idempotently and blocks duplicates", async () => {
    const ids = players.map((p) => p.id);
    const payload = {
      match_type: "ranked",
      format: "best_of_3",
      played_at: new Date(Date.now() - 3_600_000).toISOString(),
      players: lineup(ids),
      sets: [{ t1: 6, t2: 4 }, { t1: 3, t2: 6 }, { t1: 7, t2: 6, tb1: 7, tb2: 4 }],
    };
    const key = crypto.randomUUID();
    const [r1, r2] = await Promise.all([
      call("POST", "/v1/matches", { token: players[0]!.token, body: payload, headers: { "idempotency-key": key } }),
      call("POST", "/v1/matches", { token: players[0]!.token, body: payload, headers: { "idempotency-key": key } }),
    ]);
    expect(r1.status, JSON.stringify(r1.body)).toBe(201);
    expect(r2.status).toBe(201);
    expect(r1.body.id).toBe(r2.body.id);
    matchId = r1.body.id;
    expect(r1.body.status).toBe("pending");

    const dupPlayer = await call("POST", "/v1/matches", {
      token: players[0]!.token,
      body: { ...payload, players: lineup([ids[0]!, ids[0]!, ids[2]!, ids[3]!]) },
      headers: { "idempotency-key": crypto.randomUUID() },
    });
    expect(dupPlayer.body.error.code).toBe("duplicate_player");

    const badScore = await call("POST", "/v1/matches", {
      token: players[0]!.token,
      body: { ...payload, sets: [{ t1: 6, t2: 5 }, { t1: 6, t2: 4 }] },
      headers: { "idempotency-key": crypto.randomUUID() },
    });
    expect(badScore.body.error.code).toBe("invalid_score");

    const duplicate = await call("POST", "/v1/matches", {
      token: players[2]!.token,
      body: { ...payload, players: lineup([ids[2]!, ids[3]!, ids[0]!, ids[1]!]) },
      headers: { "idempotency-key": crypto.randomUUID() },
    });
    expect(duplicate.status).toBe(409);
    expect(duplicate.body.error.code).toBe("duplicate_match");
  });

  it("hides the pending match from outsiders", async () => {
    const res = await call("GET", `/v1/matches/${matchId}`, { token: outsider.token });
    expect(res.status).toBe(404);
    const confirm = await call("POST", `/v1/matches/${matchId}/confirm`, { token: outsider.token, body: { version: 1 } });
    expect(confirm.status).toBe(404);
  });

  it("applies the rating exactly once under concurrent confirmations", async () => {
    const before = await Promise.all(players.map((p) => call("GET", "/v1/me", { token: p.token })));
    const results = await Promise.all(
      players.slice(1).flatMap((p) => [
        call("POST", `/v1/matches/${matchId}/confirm`, { token: p.token, body: { version: 1 } }),
        call("POST", `/v1/matches/${matchId}/confirm`, { token: p.token, body: { version: 1 } }),
      ]),
    );
    for (const r of results) expect(r.status, JSON.stringify(r.body)).toBe(200);
    const detail = await call("GET", `/v1/matches/${matchId}`, { token: players[0]!.token });
    expect(detail.body.status).toBe("confirmed");
    expect(detail.body.rating_applied).toBe(true);
    const changes = detail.body.players.map((p: any) => p.rating_change);
    expect(changes.every((c: any) => c && typeof c.delta === "number")).toBe(true);
    const after = await Promise.all(players.map((p) => call("GET", "/v1/me", { token: p.token })));
    expect(after[0]!.body.rating.mu).toBeGreaterThan(before[0]!.body.rating.mu);
    expect(after[2]!.body.rating.mu).toBeLessThan(before[2]!.body.rating.mu);
    expect(after.every((a) => a.body.rating.ranked_matches === 1)).toBe(true);
    const history = await call("GET", `/v1/players/${players[2]!.id}/rating-history?days=30`, { token: players[0]!.token });
    expect(history.body.points.filter((p: any) => p.kind === "match")).toHaveLength(1);
  });

  it("makes the confirmed match public and immutable", async () => {
    const res = await call("GET", `/v1/matches/${matchId}`, { token: outsider.token });
    expect(res.status).toBe(200);
    const cancel = await call("POST", `/v1/matches/${matchId}/cancel`, { token: players[0]!.token, body: { version: 1 } });
    expect(cancel.body.error.code).toBe("match_locked");
  });

  it("handles disputes, edits and version conflicts", async () => {
    const ids = players.map((p) => p.id);
    const create = await call("POST", "/v1/matches", {
      token: players[1]!.token,
      body: {
        match_type: "friendly",
        format: "best_of_3_super_tiebreak",
        played_at: new Date(Date.now() - 7_200_000).toISOString(),
        players: lineup([ids[1]!, ids[0]!, ids[3]!, ids[2]!]),
        sets: [{ t1: 6, t2: 2 }, { t1: 4, t2: 6 }, { t1: 10, t2: 7, super_tiebreak: true }],
      },
      headers: { "idempotency-key": crypto.randomUUID() },
    });
    expect(create.status).toBe(201);
    const id = create.body.id;
    const dispute = await call("POST", `/v1/matches/${id}/dispute`, { token: players[2]!.token, body: { version: 1, reason: "wrong_score", comment: "Супертай-брейк был 10:8" } });
    expect(dispute.body.status).toBe("disputed");
    const edit = await call("PUT", `/v1/matches/${id}`, {
      token: players[1]!.token,
      headers: { "idempotency-key": crypto.randomUUID() },
      body: {
        version: 1,
        match: { ...create.body, match_type: "friendly", format: "best_of_3_super_tiebreak", played_at: create.body.played_at, players: lineup([ids[1]!, ids[0]!, ids[3]!, ids[2]!]), sets: [{ t1: 6, t2: 2 }, { t1: 4, t2: 6 }, { t1: 10, t2: 8, super_tiebreak: true }] },
      },
    });
    expect(edit.status, JSON.stringify(edit.body)).toBe(200);
    expect(edit.body.version).toBe(2);
    const stale = await call("POST", `/v1/matches/${id}/confirm`, { token: players[2]!.token, body: { version: 1 } });
    expect(stale.status).toBe(409);
    expect(stale.body.error.code).toBe("version_conflict");
    for (const p of [players[0]!, players[2]!, players[3]!]) {
      const r = await call("POST", `/v1/matches/${id}/confirm`, { token: p.token, body: { version: 2 } });
      expect(r.status).toBe(200);
    }
    const done = await call("GET", `/v1/matches/${id}`, { token: players[0]!.token });
    expect(done.body.status).toBe("confirmed");
    expect(done.body.rating_applied).toBe(false);

    const feedback = await call("PUT", `/v1/matches/${id}/feedback`, {
      token: players[0]!.token,
      body: { ratings: [{ player_id: ids[1], strengths: ["net_game"], improvements: [] }, { player_id: ids[2], strengths: ["defense"], improvements: ["overheads"] }] },
    });
    expect(feedback.status).toBe(200);
    expect(feedback.body.viewer.feedback).toHaveLength(2);
  });

  it("lists matches, searches players and computes insights", async () => {
    const open = await call("GET", "/v1/matches?scope=open", { token: players[0]!.token });
    expect(open.status).toBe(200);
    const history = await call("GET", "/v1/matches?scope=history", { token: players[0]!.token });
    expect(history.body.items.length).toBeGreaterThanOrEqual(2);
    const search = await call("GET", `/v1/players/search?query=${encodeURIComponent("елка")}`, { token: players[0]!.token });
    expect(search.body.items.some((p: any) => p.id === outsider.id)).toBe(true);
    expect(JSON.stringify(search.body)).not.toContain("@padelid.test");
    const profile = await call("GET", `/v1/players/${players[1]!.id}`, { token: players[0]!.token });
    expect(profile.body.compatibility.score).toBeGreaterThan(0);
    expect(profile.body.dna.dimensions).toHaveLength(6);
    const home = await call("GET", "/v1/home", { token: players[0]!.token });
    expect(home.status).toBe(200);
    expect(home.body.stats.matches).toBeGreaterThanOrEqual(2);
    const preview = await call("POST", "/v1/matches/preview", { token: players[0]!.token, body: { format: "best_of_3", players: lineup(players.map((p) => p.id)) } });
    expect(preview.body.expected_win_team1).toBeGreaterThan(0);
  });

  it("uploads and serves an avatar", async () => {
    const jpeg = new Uint8Array(2048);
    jpeg.set([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);
    jpeg.set([0xff, 0xd9], 2046);
    const res = await call("PUT", "/v1/me/avatar", { token: players[0]!.token, raw: jpeg, headers: { "content-type": "image/jpeg" } });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    const path = res.body.profile.avatar_path as string;
    expect(path.startsWith(players[0]!.id)).toBe(true);
    const img = await fetch(`${BASE}/v1/avatars/${path}`);
    expect(img.status).toBe(200);
    expect(img.headers.get("content-type")).toBe("image/jpeg");
  });

  it("changes the password, recovers with the key and changes email", async () => {
    const acc = players[3]!;
    const wrong = await call("POST", "/v1/account/password", { token: acc.token, body: { current_password: "nope-nope-1", new_password: "Padel-2027-new" } });
    expect(wrong.status).toBe(403);
    const changed = await call("POST", "/v1/account/password", { token: acc.token, body: { current_password: PASSWORD, new_password: "Padel-2027-new" } });
    expect(changed.status).toBe(204);
    expect((await call("POST", "/v1/auth/login", { body: { email: acc.email, password: PASSWORD } })).status).toBe(401);

    const badKey = await call("POST", "/v1/auth/recover", { body: { email: acc.email, recovery_key: "AAAAA-AAAAA-AAAAA-AAAAA", new_password: "Padel-2028-rec" } });
    expect(badKey.status).toBe(403);
    const recovered = await call("POST", "/v1/auth/recover", { body: { email: acc.email, recovery_key: acc.recoveryKey.toLowerCase(), new_password: "Padel-2028-rec" } });
    expect(recovered.status, JSON.stringify(recovered.body)).toBe(200);
    expect(recovered.body.recovery_key).not.toBe(acc.recoveryKey);
    const reuse = await call("POST", "/v1/auth/recover", { body: { email: acc.email, recovery_key: acc.recoveryKey, new_password: "Padel-2029-rec" } });
    expect(reuse.status).toBe(403);
    const token = recovered.body.session.access_token;
    const newEmail = `e2e-moved-${STAMP}@padelid.test`;
    const moved = await call("POST", "/v1/account/email", { token, body: { new_email: newEmail, password: "Padel-2028-rec" } });
    expect(moved.status, JSON.stringify(moved.body)).toBe(200);
    expect(moved.body.email).toBe(newEmail);
    expect((await call("POST", "/v1/auth/login", { body: { email: newEmail, password: "Padel-2028-rec" } })).status).toBe(200);
    acc.token = token;
    acc.email = newEmail;
  });

  it("deletes accounts and keeps match history consistent", async () => {
    const victim = players[3]!;
    const del = await call("DELETE", "/v1/account", { token: victim.token, body: { password: "Padel-2028-rec" } });
    expect(del.status, JSON.stringify(del.body)).toBe(204);
    expect((await call("POST", "/v1/auth/login", { body: { email: victim.email, password: "Padel-2028-rec" } })).status).toBe(401);
    const detail = await call("GET", `/v1/matches/${matchId}`, { token: players[0]!.token });
    expect(JSON.stringify(detail.body)).toContain("Удалённый игрок");
    for (const acc of [players[0]!, players[1]!, players[2]!, outsider]) {
      const r = await call("DELETE", "/v1/account", { token: acc.token, body: { password: PASSWORD } });
      expect(r.status).toBe(204);
    }
  });
});
