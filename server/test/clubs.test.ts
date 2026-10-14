import { describe, expect, it } from "vitest";
import { createApp } from "../src/api.js";
import type { Config } from "../src/config.js";
import { Upstream, type FetchFn } from "../src/upstream.js";

const config: Config = {supabaseUrl:"https://example.supabase.co",supabaseKey:"sb_publishable_test",
  gatewaySecret:"g".repeat(48),minClientBuild:5,upstreamTimeoutMs:1000,signupsPerHour:5};
const authorization = `Bearer ${"t".repeat(40)}`;
const courtId = "11111111-1111-1111-1111-111111111111";
const metadata = {version:1,reason:"Подтверждено оператором клуба",description:"Настоящий клуб",latitude:55.75,longitude:37.6,
  photo_urls:["https://photos.club.ru/court.jpg"],booking_url:"https://club.ru/booking",booking_verified:true};
const court = {version:0,name:"Корт 1",indoor:true,surface:"Искусственная трава",description:"Официальный корт",is_active:true,reason:"Проверено с клубом"};
function harness(error?: {code:string;status:number}) {
  const calls: {path:string;body:unknown;auth:string|null}[] = [];
  const fetch: FetchFn = async (input,init) => {
    const path = new URL(String(input)).pathname;
    const body = JSON.parse(String(init?.body ?? "null")) as unknown;
    if (path.endsWith("bff_rate_limit")) return new Response("true",{status:200});
    calls.push({path,body,auth:new Headers(init?.headers).get("authorization")});
    return new Response(JSON.stringify(error ? {code:"P0001",message:error.code} : {id:42,metadata_version:2,viewer:{can_edit:true}}),
      {status:error?.status ?? 200,headers:{"content-type":"application/json"}});
  };
  const app = createApp(() => ({config,upstream:new Upstream(config,fetch)}));
  return {calls,request:app.request.bind(app)};
}
function json(method:string,body:unknown) {return {method,headers:{authorization,"content-type":"application/json"},body:JSON.stringify(body)};}
describe("real clubs catalog and administration", () => {
  it("forwards canonical club/court metadata and scoped activities with bearer authorization",async () => {
    const h = harness();
    for (const [path,init,rpc,body] of [
      ["/v1/clubs/42",{headers:{authorization}},"club_detail",{p_club:42}],
      ["/v1/admin/clubs/42",json("PATCH",metadata),"admin_club_update",{p_club:42,p:metadata}],
      [`/v1/admin/clubs/42/courts/${courtId}`,json("PUT",court),"admin_court_put",{p_club:42,p_court:courtId,p:court}],
      ["/v1/clubs/42/events?kind=training&limit=10&offset=20",{headers:{authorization}},"events_catalog",{p:{club_id:42,kind:"training",scope:"upcoming",limit:10,offset:20}}],
      ["/v1/events?club_id=42",{headers:{authorization}},"events_catalog",{p:{club_id:42,scope:"upcoming",limit:30,offset:0}}],
      ["/v1/upcoming-matches?club_id=42&limit=1",{headers:{authorization}},"scheduled_matches",{p:{club_id:42,scope:"open",limit:1,offset:0}}],
    ] as const) {
      const res = await h.request(path,init);expect(res.status).toBe(200);
      expect(h.calls.at(-1)).toMatchObject({path:`/rest/v1/rpc/${rpc}`,body,auth:authorization});
    }
  });
  it("rejects fake/private URL sources, coordinate mismatches, unverified booking and unknown fields before RPC",async () => {
    for (const extra of [
      {latitude:91},{latitude:null},{longitude:undefined},{website_url:"http://club.ru/"},
      {website_url:"https://127.0.0.1/"},{website_url:"https://user:password@club.ru/"},
      {website_url:"https://a.local/"},{website_url:"https://club.ru/\\private"},
      {website_url:"https://club.ru/\u0001private"},
      {photo_urls:["data:image/jpeg;base64,abcd"]},{photo_urls:["https://localhost/"]},
      {booking_verified:false},{is_admin:true},{name:"Подмена названия"},{version:0},
    ]) {
      const h = harness();const res = await h.request("/v1/admin/clubs/42",json("PATCH",{...metadata,...extra}));
      expect(res.status,JSON.stringify(extra)).toBe(400);expect(h.calls).toHaveLength(0);
    }
  });
  it("allows explicit null clearing and sends only supplied metadata fields",async () => {
    const h = harness();const p={version:2,reason:"Ссылка больше не актуальна",latitude:null,longitude:null,booking_url:null,website_url:null};
    const res=await h.request("/v1/admin/clubs/42",json("PATCH",p));
    expect(res.status).toBe(200);expect(h.calls[0]?.body).toEqual({p_club:42,p});
  });
  it("returns fresh database authorization failures and version conflicts as actionable HTTP errors",async () => {
    for (const [code,status] of [["forbidden",403],["version_conflict",409],["club_not_found",404]] as const) {
      const h=harness({code,status:400});const res=await h.request("/v1/admin/clubs/42",json("PATCH",metadata));
      expect(res.status).toBe(status);expect((await res.json()).error.code).toBe(code);
    }
  });
  it("rejects anonymous detail reads and malformed/path/query identifiers",async () => {
    const h=harness();expect((await h.request("/v1/clubs/42")).status).toBe(401);
    for (const path of ["/v1/clubs/0","/v1/clubs/9007199254740992","/v1/clubs/1e3","/v1/clubs/42/events?club_id=43",
      "/v1/clubs/42/events?limit=0","/v1/clubs/42/events?offset=1001","/v1/clubs/42/events?kind=training&kind=tournament",
      "/v1/events?club_id=0","/v1/upcoming-matches?club_id=0"]) {
      expect((await h.request(path,{headers:{authorization}})).status,path).toBe(400);
    }
    expect(h.calls).toHaveLength(0);
  });
});
