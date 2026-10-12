// Node-only APNs transport. Never imported by the portable Edge gateway routes.
import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { connect, sensitiveHeaders, type ClientHttp2Session, type ClientHttp2Stream, type OutgoingHttpHeaders } from "node:http2";

export interface ApnsConfig {keyId:string;teamId:string;topic:string;environment:"production"|"sandbox";privateKey:string;}
export interface PushDelivery {id:string;notification_id:string;device_token:string;environment:"production"|"sandbox";topic:string;expires_at:string;}
export interface PushResult {
  outcome:"accepted"|"retry"|"dead_token"|"permanent"|"provider_error";
  reason:string|null;invalidated_at_ms?:number;
}
interface Options {connect?:(origin:string)=>ClientHttp2Session;now?:()=>number;timeoutMs?:number;}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Transport result means provider acceptance, never proof of delivery to an iPhone. */
export function classifyApnsResponse(status:number,body:unknown): PushResult {
  const row=body!==null&&typeof body==="object"?body as Record<string,unknown>:{};
  const reason=typeof row.reason==="string"&&/^[A-Za-z0-9_]{1,80}$/.test(row.reason)?row.reason:"UnknownResponse";
  if(status===200)return{outcome:"accepted",reason:null};
  if(status===400&&["BadDeviceToken","DeviceTokenNotForTopic"].includes(reason))return{outcome:"dead_token",reason};
  if(status===410&&reason==="Unregistered"&&typeof row.timestamp==="number"&&Number.isSafeInteger(row.timestamp)&&row.timestamp>=0)
    return{outcome:"dead_token",reason,invalidated_at_ms:row.timestamp};
  if(status===403||reason==="TooManyProviderTokenUpdates")return{outcome:"provider_error",reason};
  if(status===429||status>=500||status===0||status===410)return{outcome:"retry",reason};
  return{outcome:"permanent",reason};
}

export class ApnsProvider {
  private readonly key:KeyObject;
  private readonly now:()=>number;
  private readonly connector:(origin:string)=>ClientHttp2Session;
  private readonly timeoutMs:number;
  private session:ClientHttp2Session|undefined;
  private token:{value:string;issuedAt:number}|undefined;
  constructor(private readonly config:ApnsConfig,options:Options={}) {
    if(!/^[A-Z0-9]{10}$/.test(config.keyId)||!/^[A-Z0-9]{10}$/.test(config.teamId)
      ||!/^[A-Za-z0-9.-]{3,200}$/.test(config.topic)||!["sandbox","production"].includes(config.environment))throw new Error("invalid_apns_configuration");
    try{this.key=createPrivateKey(config.privateKey);}catch{throw new Error("invalid_apns_private_key");}
    if(this.key.asymmetricKeyType!=="ec"||this.key.asymmetricKeyDetails?.namedCurve!=="prime256v1")throw new Error("invalid_apns_private_key");
    this.now=options.now??Date.now;this.connector=options.connect??(origin=>connect(origin));this.timeoutMs=options.timeoutMs??10_000;
  }
  /** Apple requires ES256, with a provider token reused for 20–60 minutes. */
  private providerToken():string {
    const now=Math.floor(this.now()/1000);
    if(this.token&&now>=this.token.issuedAt&&now-this.token.issuedAt<50*60)return this.token.value;
    const header=Buffer.from(JSON.stringify({alg:"ES256",kid:this.config.keyId})).toString("base64url");
    const payload=Buffer.from(JSON.stringify({iss:this.config.teamId,iat:now})).toString("base64url");
    const unsigned=`${header}.${payload}`;
    const signature=sign("sha256",Buffer.from(unsigned),{key:this.key,dsaEncoding:"ieee-p1363"}).toString("base64url");
    this.token={value:`${unsigned}.${signature}`,issuedAt:now};return this.token.value;
  }
  private connection():ClientHttp2Session {
    if(this.session&&!this.session.closed&&!this.session.destroyed)return this.session;
    const origin=this.config.environment==="production"?"https://api.push.apple.com":"https://api.sandbox.push.apple.com";
    const session=this.connector(origin);this.session=session;
    session.on("error",()=>{session.destroy();if(this.session===session)this.session=undefined;});
    session.on("goaway",()=>{session.close();if(this.session===session)this.session=undefined;});
    return session;
  }
  async send(delivery:PushDelivery):Promise<PushResult> {
    if(delivery.environment!==this.config.environment||delivery.topic!==this.config.topic)return{outcome:"provider_error",reason:"ConfigurationMismatch"};
    if(!uuid.test(delivery.id)||!uuid.test(delivery.notification_id)||!/^[0-9a-f]{2,1024}$/.test(delivery.device_token)||delivery.device_token.length%2)
      return{outcome:"permanent",reason:"InvalidDelivery"};
    // A generic alert contains no actor, group, event, message, rating or resource ID.
    const payload=JSON.stringify({aps:{alert:{title:"Padel ID",body:"Есть новые события. Откройте приложение."},sound:"default"},notification_id:delivery.notification_id});
    const headers:OutgoingHttpHeaders={":method":"POST",":path":`/3/device/${delivery.device_token}`,
      authorization:`bearer ${this.providerToken()}`,"apns-topic":this.config.topic,"apns-push-type":"alert","apns-priority":"10",
      "apns-id":delivery.id,"apns-collapse-id":delivery.id,"apns-expiration":"0","content-type":"application/json",
      [sensitiveHeaders]:[":path","authorization","apns-id","apns-collapse-id","apns-expiration"]};
    try {
      const session=this.connection();
      return await new Promise<PushResult>(resolve=>{
        let done=false,status=0,body="";
        let stream:ClientHttp2Stream|undefined;
        let timer:ReturnType<typeof setTimeout>|undefined;
        const finish=(result:PushResult)=>{if(!done){done=true;if(timer)clearTimeout(timer);resolve(result);}};
        // Absolute deadline also covers pending connection and a slow-drip response.
        timer=setTimeout(()=>{finish({outcome:"retry",reason:"TransportTimeout"});try{stream?.close();}catch{/* already closed */}},this.timeoutMs);
        try{stream=session.request(headers);}catch{finish({outcome:"retry",reason:"TransportError"});return;}
        stream.setEncoding("utf8");
        stream.on("response",h=>{status=Number(h[":status"]??0);});
        stream.on("data",chunk=>{if(done)return;body+=String(chunk);if(Buffer.byteLength(body)>8192){finish({outcome:"retry",reason:"InvalidResponse"});stream?.close();}});
        stream.on("error",()=>finish({outcome:"retry",reason:"TransportError"}));
        stream.on("end",()=>{
          let parsed:unknown=null;
          if(body){try{parsed=JSON.parse(body);}catch{finish({outcome:"retry",reason:"InvalidResponse"});return;}}
          finish(classifyApnsResponse(status,parsed));
        });
        stream.on("close",()=>finish({outcome:"retry",reason:"TransportClosed"}));
        stream.end(payload);
      });
    }catch{return{outcome:"retry",reason:"TransportError"};}
  }
  close():void {this.session?.destroy();this.session=undefined;this.token=undefined;}
}
