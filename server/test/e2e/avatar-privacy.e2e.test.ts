// Direct Storage reads are deliberately included: gateway-only tests cannot
// detect remembered public URLs bypassing profile privacy and blocks.
import { randomUUID } from "node:crypto";
import pg from "pg";
import { beforeAll, afterAll, describe, expect, it } from "vitest";

const BASE = process.env.E2E_API_URL?.replace(/\/+$/, "");
const local = (host: string) => ["localhost", "127.0.0.1", "[::1]"].includes(host);
const RUN = Boolean(BASE && process.env.E2E_MODE !== "smoke" && local(new URL(BASE).hostname));
const STORAGE = process.env.E2E_SUPABASE_URL ?? "http://127.0.0.1:54321";
const KEY = process.env.E2E_SUPABASE_PUBLISHABLE_KEY;
const DATABASE = process.env.E2E_DATABASE_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
const PASSWORD = "Padel-avatar-2026";
interface Account { id: string; token: string; email: string; }

describe.runIf(RUN)("private avatars over real Auth and Storage", () => {
  const users: Account[] = [];
  const db = new pg.Client({ connectionString: DATABASE });
  let connected = false;
  async function api(method: string, path: string, user?: Account, body?: unknown) {
    const response = await fetch(BASE + path, { method, headers: { "x-padelid-build": "1000",
      ...(user ? { authorization: `Bearer ${user.token}` } : {}), ...(body ? { "content-type": "application/json" } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}) });
    const text = await response.text();
    return { status: response.status, body: text ? JSON.parse(text) : null };
  }
  const ok = (result: { status: number; body: any }, status = 200) => {
    expect(result.status, JSON.stringify(result.body)).toBe(status); return result.body;
  };
  const storage = (path: string, user?: Account) => fetch(STORAGE + "/storage/v1/object/" + path, {
    headers: { apikey: KEY!, ...(user ? { authorization: `Bearer ${user.token}` } : {}) }, cache: "no-store",
  });
  const gateway = (path: string, user?: Account) => fetch(BASE + "/v1/avatars/" + path, {
    headers: user ? { authorization: `Bearer ${user.token}` } : {}, cache: "no-store",
  });
  beforeAll(async () => {
    expect(KEY, "Full local Storage regressions require E2E_SUPABASE_PUBLISHABLE_KEY").toBeTruthy();
    expect(local(new URL(STORAGE).hostname)).toBe(true);
    const database = new URL(DATABASE); expect(local(database.hostname)).toBe(true); expect(database.port).toBe("54322");
    await db.connect(); connected = true;
    for (let index = 0; index < 2; index++) {
      const stamp = randomUUID().replaceAll("-", "").slice(0, 10);
      const email = `avatar-${stamp}@padelid.test`;
      const signup = ok(await api("POST", "/v1/auth/signup", undefined, { email, password: PASSWORD }), 201);
      const user = { id: signup.session.user.id, token: signup.session.access_token, email }; users.push(user);
      ok(await api("POST", "/v1/me/onboarding", user, {
        username: `av_${stamp}`, display_name: ["Анна Ким", "Борис Ким"][index], city_id: 1, preferred_side: "both", dominant_hand: "right",
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
          const session = ok(await api("POST", "/v1/auth/login", undefined, { email: user.email, password: PASSWORD }));
          ok(await api("DELETE", "/v1/account", { ...user, token: session.access_token }, { password: PASSWORD }), 204);
        } catch (error) { failures.push(error); }
      }
    } finally { if (connected) await db.end(); }
    if (failures.length) throw new AggregateError(failures, "Avatar fixture cleanup failed");
  }, 90_000);

  it("denies public URLs and enforces privacy, block, current photo and live sessions in Storage itself", async () => {
    const [owner, viewer] = users as [Account, Account];
    const jpeg = new Uint8Array(2048); jpeg.set([0xff, 0xd8, 0xff, 0xe0]); jpeg.set([0xff, 0xd9], 2046);
    async function upload() {
      const response = await fetch(BASE + "/v1/me/avatar", { method: "PUT", headers: {
        authorization: `Bearer ${owner.token}`, "content-type": "image/jpeg" }, body: jpeg });
      const body = await response.json(); expect(response.status, JSON.stringify(body)).toBe(200); return body.profile.avatar_path as string;
    }
    const path = await upload();
    expect((await db.query("select public from storage.buckets where id='avatars'")).rows[0].public).toBe(false);
    expect((await storage("public/avatars/" + path)).ok).toBe(false);
    expect((await storage("authenticated/avatars/" + path)).ok).toBe(false);
    expect((await storage("authenticated/avatars/" + path, owner)).status).toBe(200);
    expect((await storage("authenticated/avatars/" + path, viewer)).status).toBe(200);
    const replace = (user: Account) => fetch(STORAGE + "/storage/v1/object/avatars/" + path, {
      method: "PUT", headers: { authorization: `Bearer ${user.token}`, apikey: KEY!, "content-type": "image/jpeg" }, body: jpeg });
    expect((await replace(owner)).status).toBe(200);
    expect((await replace(viewer)).ok).toBe(false);
    const foreignUpload = await fetch(STORAGE + `/storage/v1/object/avatars/${owner.id}/foreignphoto123.jpg`, {
      method: "POST", headers: { authorization: `Bearer ${viewer.token}`, apikey: KEY!, "content-type": "image/jpeg" }, body: jpeg });
    expect(foreignUpload.ok).toBe(false);
    expect((await gateway(path)).status).toBe(401);
    expect((await gateway(path, viewer)).status).toBe(200);
    for (const user of [owner, viewer]) {
      const signed = await fetch(STORAGE + "/storage/v1/object/sign/avatars/" + path, { method: "POST", headers: {
        authorization: `Bearer ${user.token}`, apikey: KEY!, "content-type": "application/json" }, body: JSON.stringify({ expiresIn: 3600 }) });
      expect(signed.ok).toBe(false);
      const signedBody = await signed.json(); expect(signedBody.signedURL).toBeUndefined();
      const uploadSign = await fetch(STORAGE + `/storage/v1/object/upload/sign/avatars/${user.id}/signedphoto123.jpg`, {
        method: "POST", headers: { authorization: `Bearer ${user.token}`, apikey: KEY!, "content-type": "application/json" },
        body: "{}" });
      expect(uploadSign.ok).toBe(false);
      const uploadSignBody = await uploadSign.json(); expect(uploadSignBody.token).toBeUndefined();
    }
    ok(await api("PATCH", "/v1/me", owner, { discoverable: false }));
    expect((await storage("authenticated/avatars/" + path, viewer)).ok).toBe(false);
    expect((await gateway(path, viewer)).status).toBe(404);
    expect((await storage("authenticated/avatars/" + path, owner)).status).toBe(200);
    ok(await api("PATCH", "/v1/me", owner, { discoverable: true }));
    ok(await api("PUT", `/v1/social/blocks/${owner.id}`, viewer));
    expect((await storage("authenticated/avatars/" + path, viewer)).ok).toBe(false);
    expect((await gateway(path, viewer)).status).toBe(404);
    ok(await api("DELETE", `/v1/social/blocks/${owner.id}`, viewer));
    expect((await storage("authenticated/avatars/" + path, viewer)).status).toBe(200);
    // A leftover object really exists, but a visible profile does not
    // authorize old/non-current photographs.
    const leftover = `${owner.id}/oldphoto123.jpg`;
    const stored = await fetch(STORAGE + "/storage/v1/object/avatars/" + leftover, { method: "POST", headers: {
      authorization: `Bearer ${owner.token}`, apikey: KEY!, "content-type": "image/jpeg" }, body: jpeg });
    expect(stored.status).toBe(200);
    expect((await storage("authenticated/avatars/" + leftover, owner)).status).toBe(200);
    expect((await storage("authenticated/avatars/" + leftover, viewer)).ok).toBe(false);
    ok(await api("DELETE", "/v1/me/avatar", owner));
    expect((await storage("authenticated/avatars/" + path, viewer)).ok).toBe(false);
    const current = await upload();
    await db.query("update auth.sessions set not_after=now()-interval '1 second' where user_id=$1", [viewer.id]);
    expect((await storage("authenticated/avatars/" + current, viewer)).ok).toBe(false);
    expect((await gateway(current, viewer)).status).toBe(401);
    await db.query("update auth.sessions set not_after=now()-interval '1 second' where user_id=$1", [owner.id]);
    expect((await storage("authenticated/avatars/" + current, owner)).ok).toBe(false);
    const staleUpload = await fetch(STORAGE + `/storage/v1/object/avatars/${owner.id}/staletoken123.jpg`, {
      method: "POST", headers: { authorization: `Bearer ${owner.token}`, apikey: KEY!, "content-type": "image/jpeg" }, body: jpeg });
    expect(staleUpload.ok).toBe(false);
  }, 60_000);
});
