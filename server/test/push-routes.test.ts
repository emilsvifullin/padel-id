import { describe, expect, it } from "vitest";
import { createApp } from "../src/api.js";
import type { Config } from "../src/config.js";
import { Upstream, type FetchFn } from "../src/upstream.js";
const config:Config={supabaseUrl:"https://example.supabase.co",supabaseKey:"sb_publishable_test",gatewaySecret:"g".repeat(40),minClientBuild:1,upstreamTimeoutMs:1000,signupsPerHour:5};
const installation="11111111-1111-4111-8111-111111111111",authorization=`Bearer ${"t".repeat(40)}`;
function harness(){
 const calls:{path:string;body:unknown;auth:string|null}[]=[];
 const fetch:FetchFn=async(input,init)=>{
  const path=new URL(String(input)).pathname;
  if(path.endsWith("bff_rate_limit"))return new Response("true",{status:200});
  calls.push({path,body:JSON.parse(String(init?.body)),auth:new Headers(init?.headers).get("authorization")});
  return new Response(JSON.stringify({installation_id:installation,enabled:true,environment:"production",topic:"app.padelid.ios",generation:1,registered_at:"2026-10-11T00:00:00Z"}),{status:200});
 };
 const app=createApp(()=>({config,upstream:new Upstream(config,fetch)}));return{request:app.request.bind(app),calls};
}
function put(body:unknown,auth=true){return{method:"PUT",headers:{"content-type":"application/json",...(auth?{authorization}:{})},body:JSON.stringify(body)};}
describe("portable authenticated push registration",()=>{
 it("normalizes opaque variable-length tokens while forwarding only the current bearer and installation",async()=>{
  const h=harness();const res=await h.request(`/v1/me/push-devices/${installation}`,put({device_token:"AABB",enabled:true}));
  expect(res.status).toBe(200);expect(h.calls[0]).toEqual({path:"/rest/v1/rpc/register_push_device",body:{p_installation:installation,p_token:"aabb",p_enabled:true},auth:authorization});
  await h.request(`/v1/me/push-devices/${installation}`,{method:"DELETE",headers:{authorization}});
  expect(h.calls[1]).toEqual({path:"/rest/v1/rpc/revoke_push_device",body:{p_installation:installation},auth:authorization});
 });
 it("rejects spoofed owner/topic/environment, nonhex/odd/oversized tokens and missing permission state before RPC",async()=>{
  for(const value of[{device_token:"aabb",enabled:true,environment:"sandbox"},{device_token:"aabb",enabled:true,topic:"other"},
   {device_token:"aabb",enabled:true,player_id:installation},{device_token:"aabb"},{device_token:"abc",enabled:true},
   {device_token:"xx",enabled:true},{device_token:"aa".repeat(513),enabled:true}]){
   const h=harness();expect((await h.request(`/v1/me/push-devices/${installation}`,put(value))).status).toBe(400);expect(h.calls).toHaveLength(0);
  }
 });
 it("requires actual authentication for both registration and revocation",async()=>{
  const h=harness();expect((await h.request(`/v1/me/push-devices/${installation}`,put({device_token:"aabb",enabled:true},false))).status).toBe(401);
  expect((await h.request(`/v1/me/push-devices/${installation}`,{method:"DELETE"})).status).toBe(401);expect(h.calls).toHaveLength(0);
 });
});
