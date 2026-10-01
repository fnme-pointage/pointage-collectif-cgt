const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict'),{stripTypeScriptTypes}=require('node:module');
const source=fs.readFileSync('app/supabase/functions/contact-admin/index.ts','utf8').replace(/^import .*;\n/gm,'');
const js=stripTypeScriptTypes(source,{mode:'strip'});
async function scenario({token='valid',origin='https://fnme-pointage.github.io',active=true,limit=true,fail=false,body={subject:'Test',message:'Message test'},method='POST'}={}){
 let handler,sends=0,lastMail=null,claims=0,closed=false;
 const sb={auth:{getUser:async()=>({data:{user:token==='valid'?{id:'verified-id',email:'member@example.invalid'}:null},error:null})},from:table=>({select:()=>({eq:()=>({single:async()=>({data:table==='profiles'?{id:'verified-id',full_name:'Utilisateur',unit_id:'ulm',active,is_admin:false}:{name:'ULM'},error:null})})})}),rpc:async(name,args)=>{claims++;assert.equal(args.p_user,'verified-id');return {data:limit,error:null};}};
 const context={Response,Request,console:{error:()=>{}},createClient:()=>sb,nodemailer:{createTransport:()=>({sendMail:async mail=>{sends++;lastMail=mail;if(fail)throw Error('SMTP failed');return {accepted:['fnme.pointage@gmail.com']};},close:()=>{closed=true}})},Deno:{env:{get:key=>key==='POINTAGE_GMAIL_APP_PASSWORD'?'abcdefghijklmnop':'test-config'},serve:fn=>{handler=fn}}};
 vm.createContext(context);vm.runInContext(js,context);
 const headers={'Origin':origin,'Content-Type':'application/json'};if(token)headers.Authorization='Bearer '+token;
 const req=new Request('https://example.invalid',{method,headers,...(method==='POST'?{body:JSON.stringify(body)}:{})});
 const res=await handler(req);return {status:res.status,sends,lastMail,claims,closed};
}
(async()=>{
 let r=await scenario({token:''});assert.equal(r.status,401);assert.equal(r.sends,0);
 r=await scenario({token:'invalid'});assert.equal(r.status,401);assert.equal(r.sends,0);
 r=await scenario({active:false});assert.equal(r.status,403);assert.equal(r.sends,0);
 r=await scenario({origin:'https://evil.invalid'});assert.equal(r.status,403);assert.equal(r.sends,0);
 r=await scenario({body:{subject:'Injected\r\nTo: attacker',message:'test'}});assert.equal(r.status,400);assert.equal(r.sends,0);
 r=await scenario({body:{subject:'Test',message:'x'.repeat(5001)}});assert.equal(r.status,400);assert.equal(r.sends,0);
 r=await scenario({limit:false});assert.equal(r.status,429);assert.equal(r.sends,0);
 r=await scenario({body:{subject:'Test',message:'Message',to:'attacker@example.invalid',user_id:'spoofed'}});assert.equal(r.status,200);assert.equal(r.sends,1);assert.equal(r.lastMail.to,'fnme.pointage@gmail.com');assert.equal(r.lastMail.replyTo.address,'member@example.invalid');assert.match(r.lastMail.text,/ULM/);assert.equal(r.closed,true);
 r=await scenario({fail:true});assert.equal(r.status,502);assert.equal(r.closed,true);
 console.log('PASS: verified sender, inactive/unauthenticated denied, origin and payload checks, fixed recipient, reply-to, rate limit and SMTP failure; no real mail sent.');
})().catch(e=>{console.error(e);process.exit(1)});
