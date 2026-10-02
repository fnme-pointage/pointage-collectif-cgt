const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict'),{stripTypeScriptTypes}=require('node:module');
const js=stripTypeScriptTypes(fs.readFileSync('app/supabase/functions/notify-user-activation/index.ts','utf8').replace(/^import .*;\n/gm,''),{mode:'strip'});
async function scenario({token='valid',fail=false,rejected=false,configured=true,claimError=false}={}) {
 let handler,mail,finish,closed=false,claims=0;
 const sb={rpc:async(name,args)=>{
  if(name==='pointage_notification_authorized')return {data:token==='valid'};
  if(name==='pointage_claim_activation_notifications'){claims++;return {data:[{id:'q',claim_id:'claim',user_id:'user',email:'verified@example.invalid',full_name:'Jean <test>',unit_name:'Unité & A'}],error:claimError?{}:null};}
  assert.equal(name,'pointage_finish_activation_notification');finish=args;return {error:null};
 }};
 const context={Response,Request,console:{error:()=>{}},createClient:()=>sb,nodemailer:{createTransport:()=>({sendMail:async m=>{mail=m;if(fail)throw {code:'ETIMEDOUT'};return {accepted:rejected?[]:['verified@example.invalid']};},close:()=>closed=true})},Deno:{env:{get:k=>k==='POINTAGE_GMAIL_APP_PASSWORD'?(configured?'abcdefghijklmnop':null):'config'},serve:f=>handler=f}};
 vm.createContext(context);vm.runInContext(js,context);
 const response=await handler(new Request('https://example.invalid',{method:'POST',headers:token?{'x-pointage-notification-token':token}:{},body:JSON.stringify({to:'attacker@example.invalid'})}));
 return {status:response.status,mail,finish,closed,claims};
}
(async()=>{
 for(const token of ['', 'invalid']){const r=await scenario({token});assert.equal(r.status,401);assert.equal(r.mail,undefined);}
 let r=await scenario({configured:false});assert.equal(r.status,503);assert.equal(r.claims,0);
 r=await scenario();assert.equal(r.status,200);assert.equal(r.mail.to,'verified@example.invalid');assert.equal(r.mail.from.address,'fnme.pointage@gmail.com');assert.match(r.mail.text,/Unité & A/);assert.match(r.mail.text,/https:\/\/fnme-pointage.github.io/);assert.match(r.mail.html,/Jean &lt;test&gt;/);assert.equal(r.finish.p_sent,true);assert.equal(r.closed,true);
 r=await scenario({fail:true});assert.equal(r.finish.p_sent,false);assert.equal(r.finish.p_error,'ETIMEDOUT');assert.equal(r.closed,true);
 r=await scenario({rejected:true});assert.equal(r.finish.p_sent,false);assert.equal(r.finish.p_error,'RECIPIENT_REJECTED');
 r=await scenario({claimError:true});assert.equal(r.status,500);assert.equal(r.mail,undefined);assert.equal(r.closed,true);
 console.log('PASS: authorization, database recipient, message, escaping, SMTP rejection/retry, missing configuration; no real mail sent.');
})().catch(e=>{console.error(e);process.exit(1)});
