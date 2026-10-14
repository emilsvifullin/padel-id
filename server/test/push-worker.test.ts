import { describe, expect, it, vi } from "vitest";
import { loadPushWorkerConfig, RpcPushStore, runPushBatch, type PushStore } from "../src/push-worker.js";
import type { PushDelivery, PushResult } from "../src/push-provider.js";
const job={id:"11111111-1111-4111-8111-111111111111",lease_id:"22222222-2222-4222-8222-222222222222"};
const delivery:PushDelivery={...job,notification_id:"33333333-3333-4333-8333-333333333333",device_token:"aabb",environment:"production",topic:"app.padelid.ios",expires_at:"2026-10-12T00:00:00Z"};
function store(authorize:PushDelivery|null=delivery,updated=true){return{claim:vi.fn(async()=>({items:[job]})),authorize:vi.fn(async()=>authorize),finish:vi.fn(async()=>({updated}))}satisfies PushStore;}
describe("private push worker",()=>{
  it("rechecks current authorization before send and suppresses revoked jobs",async()=>{
    const db=store(null),send=vi.fn(async():Promise<PushResult>=>({outcome:"accepted",reason:null}));
    expect(await runPushBatch(db,{send})).toMatchObject({claimed:1,skipped:1,accepted:0});
    expect(send).not.toHaveBeenCalled();expect(db.finish).not.toHaveBeenCalled();
    const mismatch=store({...delivery,id:"44444444-4444-4444-8444-444444444444"});
    expect(await runPushBatch(mismatch,{send})).toMatchObject({skipped:1});expect(send).not.toHaveBeenCalled();
  });
  it("records APNs acceptance only after provider success and a current lease acknowledgment",async()=>{
    const db=store(),send=vi.fn(async():Promise<PushResult>=>({outcome:"accepted",reason:null}));
    expect(await runPushBatch(db,{send})).toMatchObject({accepted:1});expect(db.finish).toHaveBeenCalledWith(job.id,job.lease_id,{outcome:"accepted",reason:null});
    expect(await runPushBatch(store(delivery,false),{send})).toMatchObject({accepted:0,lease_lost:1});
  });
  it("converts thrown provider errors into a bounded queue retry",async()=>{
    const db=store();expect(await runPushBatch(db,{send:async()=>{throw new Error("could contain sensitive request");}})).toMatchObject({retry:1});
    expect(db.finish).toHaveBeenCalledWith(job.id,job.lease_id,{outcome:"retry",reason:"ProviderTransportError"});
  });
  it("stops a batch on key/topic failure without invalidating unrelated destinations",async()=>{
    const db=store();db.claim=vi.fn(async()=>({items:[job,{...job,id:"44444444-4444-4444-8444-444444444444"}]}));
    const send=vi.fn(async():Promise<PushResult>=>({outcome:"provider_error",reason:"InvalidProviderToken"}));
    expect(await runPushBatch(db,{send})).toMatchObject({claimed:2,provider_error:1,dead_token:0});expect(send).toHaveBeenCalledTimes(1);
  });
  it("uses dedicated worker authorization and never returns raw upstream error content",async()=>{
    const calls:RequestInit[]=[];const secret="test-worker-".repeat(4);
    const db=new RpcPushStore({supabaseUrl:"https://example.supabase.co",supabaseKey:"sb_publishable_test",workerSecret:secret},async(_,init)=>{
      calls.push(init!);return new Response(JSON.stringify({items:[job]}),{status:200});});
    expect(await db.claim(10)).toEqual({items:[job]});expect(JSON.parse(String(calls[0]!.body))).toEqual({p_limit:10,p_secret:secret});
    expect(new Headers(calls[0]!.headers).get("authorization")).toBeNull();
    const bad=new RpcPushStore({supabaseUrl:"https://example.supabase.co",supabaseKey:"test",workerSecret:secret},async()=>new Response(secret,{status:403}));
    await expect(bad.claim(10)).rejects.toThrow("push_store_unavailable");
    expect(()=>new RpcPushStore({supabaseUrl:"http://example.supabase.co",supabaseKey:"test",workerSecret:secret})).toThrow("invalid_push_worker_configuration");
  });
  it("fails closed without actual provisioning and requires a fixed Apple environment",()=>{
    expect(()=>loadPushWorkerConfig({})).toThrow("missing_push_worker_configuration");
    const env={SUPABASE_URL:"https://example.supabase.co",SUPABASE_PUBLISHABLE_KEY:"test",PADELID_PUSH_WORKER_SECRET:"t".repeat(40),
      PADELID_APNS_KEY_ID:"ABC123DEFG",PADELID_APNS_TEAM_ID:"DEF123GHIJ",PADELID_APNS_TOPIC:"app.padelid.ios",PADELID_APNS_PRIVATE_KEY:"test",PADELID_APNS_ENVIRONMENT:"development"};
    expect(()=>loadPushWorkerConfig(env)).toThrow("invalid_push_worker_configuration");
  });
});
