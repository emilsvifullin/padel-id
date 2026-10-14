// Standalone Node worker; never wired to a public gateway endpoint.
import { pathToFileURL } from "node:url";
import { ApnsProvider, type ApnsConfig, type PushDelivery, type PushResult } from "./push-provider.js";
import { z } from "zod";

const uuid=z.uuid();
const claimSchema=z.strictObject({items:z.array(z.strictObject({id:uuid,lease_id:uuid})).max(50)});
const deliverySchema=z.strictObject({id:uuid,notification_id:uuid,device_token:z.string().regex(/^[a-f0-9]{2,1024}$/),
  environment:z.enum(["production","sandbox"]),topic:z.string().min(3).max(200),expires_at:z.string()});
export interface PushStore {
  claim(limit:number):Promise<z.infer<typeof claimSchema>>;
  authorize(id:string,lease:string):Promise<PushDelivery|null>;
  finish(id:string,lease:string,result:PushResult):Promise<{updated:boolean}>;
}
export class RpcPushStore implements PushStore {
  constructor(private readonly config:{supabaseUrl:string;supabaseKey:string;workerSecret:string},private readonly fetchImpl:typeof fetch=fetch) {
    if(config.workerSecret.length<32)throw new Error("invalid_push_worker_configuration");
    let url:URL;try{url=new URL(config.supabaseUrl);}catch{throw new Error("invalid_push_worker_configuration");}
    if(url.protocol!=="https:"||url.username||url.password||url.search||url.hash||!["","/"].includes(url.pathname))throw new Error("invalid_push_worker_configuration");
  }
  private async rpc(name:string,args:Record<string,unknown>):Promise<unknown> {
    let response:Response;
    try{response=await this.fetchImpl(`${this.config.supabaseUrl.replace(/\/+$/,"")}/rest/v1/rpc/${name}`,{
      method:"POST",headers:{apikey:this.config.supabaseKey,"content-type":"application/json"},
      body:JSON.stringify({...args,p_secret:this.config.workerSecret}),signal:AbortSignal.timeout(12_000)});}catch{throw new Error("push_store_unavailable");}
    if(!response.ok)throw new Error("push_store_unavailable");
    try{return await response.json();}catch{throw new Error("invalid_push_store_response");}
  }
  async claim(limit:number){return claimSchema.parse(await this.rpc("claim_push_deliveries",{p_limit:limit}));}
  async authorize(id:string,lease:string):Promise<PushDelivery|null>{
    const row=await this.rpc("authorize_push_delivery",{p_job:id,p_lease:lease});return row===null?null:deliverySchema.parse(row);
  }
  async finish(id:string,lease:string,result:PushResult){
    return z.strictObject({updated:z.boolean()}).parse(await this.rpc("finish_push_delivery",{
      p_job:id,p_lease:lease,p_outcome:result.outcome,p_reason:result.reason,p_invalidated_at_ms:result.invalidated_at_ms??null}));
  }
}
export async function runPushBatch(store:PushStore,provider:Pick<ApnsProvider,"send">,limit=10) {
  const summary={claimed:0,accepted:0,retry:0,dead_token:0,failed:0,skipped:0,lease_lost:0,provider_error:0};
  const batch=await store.claim(limit);summary.claimed=batch.items.length;
  for(const job of batch.items){
    const delivery=await store.authorize(job.id,job.lease_id);
    if(!delivery||delivery.id!==job.id){summary.skipped++;continue;}
    let result:PushResult;
    try{result=await provider.send(delivery);}catch{result={outcome:"retry",reason:"ProviderTransportError"};}
    const finished=await store.finish(job.id,job.lease_id,result);
    if(!finished.updated){summary.lease_lost++;continue;}
    switch(result.outcome){case"accepted":summary.accepted++;break;case"retry":summary.retry++;break;
      case"dead_token":summary.dead_token++;break;case"permanent":summary.failed++;break;case"provider_error":summary.provider_error++;break;}
    // An invalid Apple key/topic is an operational problem; don't burn every job/device.
    if(result.outcome==="provider_error")break;
  }
  return summary;
}
export function loadPushWorkerConfig(env:Record<string,string|undefined>=process.env) {
  const required=["SUPABASE_URL","SUPABASE_PUBLISHABLE_KEY","PADELID_PUSH_WORKER_SECRET","PADELID_APNS_KEY_ID","PADELID_APNS_TEAM_ID","PADELID_APNS_TOPIC","PADELID_APNS_ENVIRONMENT","PADELID_APNS_PRIVATE_KEY"] as const;
  if(required.some(key=>!env[key]))throw new Error("missing_push_worker_configuration");
  const environment=env.PADELID_APNS_ENVIRONMENT;
  if(environment!=="production"&&environment!=="sandbox")throw new Error("invalid_push_worker_configuration");
  const store={supabaseUrl:env.SUPABASE_URL!,supabaseKey:env.SUPABASE_PUBLISHABLE_KEY!,workerSecret:env.PADELID_PUSH_WORKER_SECRET!};
  const apns:ApnsConfig={keyId:env.PADELID_APNS_KEY_ID!,teamId:env.PADELID_APNS_TEAM_ID!,topic:env.PADELID_APNS_TOPIC!,environment,privateKey:env.PADELID_APNS_PRIVATE_KEY!};
  return{store,apns};
}
async function main(){
  const config=loadPushWorkerConfig(),provider=new ApnsProvider(config.apns);
  try{const summary=await runPushBatch(new RpcPushStore(config.store),provider);process.stdout.write(JSON.stringify(summary)+"\n");}
  finally{provider.close();}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  void main().catch(()=>{process.stderr.write("push_worker_failed\n");process.exitCode=1;});
}
