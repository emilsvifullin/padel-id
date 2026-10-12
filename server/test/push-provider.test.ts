import { afterEach, describe, expect, it } from "vitest";
import { createPublicKey, generateKeyPairSync, verify } from "node:crypto";
import { connect, createServer, type ClientHttp2Session, type IncomingHttpHeaders, type ServerHttp2Stream } from "node:http2";
import { EventEmitter } from "node:events";
import { ApnsProvider, classifyApnsResponse, type PushDelivery } from "../src/push-provider.js";

const pair=generateKeyPairSync("ec",{namedCurve:"prime256v1"});
const privateKey=pair.privateKey.export({type:"pkcs8",format:"pem"}).toString();
const config={keyId:"ABC123DEFG",teamId:"DEF123GHIJ",topic:"app.padelid.ios",environment:"production" as const,privateKey};
const delivery:PushDelivery={id:"11111111-1111-4111-8111-111111111111",notification_id:"22222222-2222-4222-8222-222222222222",
  device_token:"aabbccdd",environment:"production",topic:"app.padelid.ios",expires_at:"2026-10-12T00:00:00Z"};
const cleaners:(()=>Promise<void>|void)[]=[];
afterEach(async()=>{for(const clean of cleaners.splice(0).reverse())await clean();});
async function server(handler:(stream:ServerHttp2Stream,headers:IncomingHttpHeaders)=>void) {
  const app=createServer();app.on("stream",handler);
  await new Promise<void>(resolve=>app.listen(0,"127.0.0.1",resolve));
  const address=app.address();if(!address||typeof address==="string")throw new Error("test_server_failed");
  cleaners.push(()=>new Promise<void>(resolve=>app.close(()=>resolve())));
  return `http://127.0.0.1:${address.port}`;
}
function provider(local:string,options:{now?:()=>number;timeoutMs?:number}={}) {
  const origins:string[]=[];
  const p=new ApnsProvider(config,{...options,connect:origin=>{origins.push(origin);return connect(local);}});
  cleaners.push(()=>p.close());return{p,origins};
}
describe("Node APNs HTTP/2 provider",()=>{
  it("signs verifiable ES256 JWTs, reuses 50-minute provider tokens and emits only a generic opaque payload",async()=>{
    const requests:{headers:IncomingHttpHeaders;body:string}[]=[];
    const local=await server((stream,headers)=>{let body="";stream.setEncoding("utf8");stream.on("data",v=>body+=v);stream.on("end",()=>{requests.push({headers,body});stream.respond({":status":200});stream.end();});});
    let time=1_800_000_000_000;const{p,origins}=provider(local,{now:()=>time});
    expect(await p.send({...delivery,...{actor_id:"secret actor",body:"secret text"}})).toEqual({outcome:"accepted",reason:null});
    time+=19*60_000;await p.send(delivery);time+=31*60_000;await p.send(delivery);
    expect(origins).toEqual(["https://api.push.apple.com"]);
    const headers=requests[0]!.headers;
    expect(headers[":method"]).toBe("POST");expect(headers[":path"]).toBe("/3/device/aabbccdd");
    expect(headers["apns-topic"]).toBe(config.topic);expect(headers["apns-push-type"]).toBe("alert");
    expect(headers["apns-id"]).toBe(delivery.id);expect(headers["apns-collapse-id"]).toBe(delivery.id);expect(headers["apns-expiration"]).toBe("0");
    const token=String(headers.authorization).slice(7);const[head,payload,signature]=token.split(".");
    expect(JSON.parse(Buffer.from(head!,"base64url").toString())).toEqual({alg:"ES256",kid:config.keyId});
    expect(JSON.parse(Buffer.from(payload!,"base64url").toString())).toEqual({iss:config.teamId,iat:1_800_000_000});
    expect(Buffer.from(signature!,"base64url")).toHaveLength(64);
    expect(verify("sha256",Buffer.from(`${head}.${payload}`),{key:createPublicKey(pair.privateKey),dsaEncoding:"ieee-p1363"},Buffer.from(signature!,"base64url"))).toBe(true);
    expect(requests[1]!.headers.authorization).toBe(headers.authorization);expect(requests[2]!.headers.authorization).not.toBe(headers.authorization);
    expect(JSON.parse(requests[0]!.body)).toEqual({aps:{alert:{title:"Padel ID",body:"Есть новые события. Откройте приложение."},sound:"default"},notification_id:delivery.notification_id});
    expect(requests[0]!.body).not.toContain("secret");
  });
  it("classifies dead tokens without treating credential problems as invalid devices",()=>{
    for(const[status,body,outcome]of[
      [200,null,"accepted"],[400,{reason:"BadDeviceToken"},"dead_token"],[400,{reason:"DeviceTokenNotForTopic"},"dead_token"],
      [410,{reason:"Unregistered",timestamp:1_800_000_000_000},"dead_token"],[410,{reason:"Unregistered"},"retry"],
      [403,{reason:"InvalidProviderToken"},"provider_error"],[429,{reason:"TooManyProviderTokenUpdates"},"provider_error"],
      [429,{reason:"TooManyRequests"},"retry"],[500,{reason:"InternalServerError"},"retry"],[503,{reason:"Shutdown"},"retry"],
      [400,{reason:"PayloadTooLarge"},"permanent"],
    ]as const)expect(classifyApnsResponse(status,body).outcome).toBe(outcome);
    expect(classifyApnsResponse(410,{reason:"Unregistered",timestamp:1_800_000_000_000}).invalidated_at_ms).toBe(1_800_000_000_000);
  });
  it("enforces a total deadline for an actively dripping response",async()=>{
    const local=await server(stream=>{stream.respond({":status":503});const timer=setInterval(()=>stream.write(" "),10);stream.on("close",()=>clearInterval(timer));});
    const{p}=provider(local,{timeoutMs:60});const start=Date.now();
    expect(await p.send(delivery)).toEqual({outcome:"retry",reason:"TransportTimeout"});
    expect(Date.now()-start).toBeLessThan(500);
  });
  it("terminates a never-connecting stream once and ignores data after its deadline",async()=>{
    const stream=new EventEmitter()as EventEmitter&{setEncoding:()=>void;end:()=>void;close:()=>void};
    stream.setEncoding=()=>{};stream.end=()=>{};let closes=0;stream.close=()=>{closes++;stream.emit("close");};
    const fake=new EventEmitter()as EventEmitter&{request:()=>typeof stream;closed:boolean;destroyed:boolean;destroy:()=>void};
    fake.request=()=>stream;fake.closed=false;fake.destroyed=false;fake.destroy=()=>{};
    const p=new ApnsProvider(config,{timeoutMs:20,connect:()=>fake as unknown as ClientHttp2Session});cleaners.push(()=>p.close());
    expect(await p.send(delivery)).toEqual({outcome:"retry",reason:"TransportTimeout"});
    stream.emit("data","x".repeat(100_000));stream.emit("end");expect(closes).toBe(1);
  });
  it("handles abrupt response close and malformed responses without leaking bodies",async()=>{
    const local=await server(stream=>{stream.respond({":status":503});stream.close();});const{p}=provider(local,{timeoutMs:100});
    const result=await p.send(delivery);expect(result.outcome).toBe("retry");
    expect(["TransportClosed","UnknownResponse","TransportError"]).toContain(result.reason);
  });
  it("rejects topic/environment mismatch before creating an Apple connection",async()=>{
    const p=new ApnsProvider(config,{connect:()=>{throw new Error("must_not_connect");}});cleaners.push(()=>p.close());
    expect(await p.send({...delivery,environment:"sandbox"})).toEqual({outcome:"provider_error",reason:"ConfigurationMismatch"});
    expect(()=>new ApnsProvider({...config,privateKey:"invalid test key"})).toThrow("invalid_apns_private_key");
  });
});
