import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import nodemailer from "npm:nodemailer@8.0.11";

const recipient = "fnme.pointage@gmail.com";
const appOrigin = "https://fnme-pointage.github.io";
const cors = {"Access-Control-Allow-Origin":appOrigin,"Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
const json = (body: Record<string,unknown>,status=200) => Response.json(body,{status,headers:cors});

Deno.serve(async (request: Request) => {
  const origin=request.headers.get("origin");
  if(origin && origin!==appOrigin)return json({error:"ORIGIN_DENIED"},403);
  if(request.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
  if(request.method!=="POST")return json({error:"METHOD_NOT_ALLOWED"},405);
  const token=request.headers.get("authorization")?.match(/^Bearer (.+)$/i)?.[1];
  if(!token)return json({error:"AUTH_REQUIRED"},401);
  const sb=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:auth,error:authError}=await sb.auth.getUser(token);
  const user=auth?.user;
  if(authError || !user?.email || /[\r\n]/.test(user.email))return json({error:"AUTH_REQUIRED"},401);
  const {data:profile,error:profileError}=await sb.from("profiles").select("id,full_name,unit_id,active,is_admin").eq("id",user.id).single();
  if(profileError || !profile?.active || profile.is_admin)return json({error:"ACCOUNT_NOT_ACTIVE"},403);
  let body: {subject?:unknown;message?:unknown};
  try{const raw=await request.text();if(raw.length>20000)return json({error:"MESSAGE_TOO_LONG"},400);body=JSON.parse(raw);}catch{return json({error:"INVALID_MESSAGE"},400);}
  if(typeof body?.subject!=="string" || typeof body?.message!=="string")return json({error:"INVALID_MESSAGE"},400);
  const subject=body.subject.trim(),message=body.message.trim();
  if(!subject || subject.length>160 || /[\r\n]/.test(subject) || !message || message.length>5000)return json({error:"INVALID_MESSAGE"},400);
  const password=Deno.env.get("POINTAGE_GMAIL_APP_PASSWORD")?.replace(/\s/g,"");
  if(!password || !/^[a-z]{16}$/.test(password))return json({error:"MAIL_UNAVAILABLE"},503);
  const {data:allowed,error:limitError}=await sb.rpc("pointage_claim_contact_send",{p_user:user.id});
  if(limitError)return json({error:"MAIL_UNAVAILABLE"},503);
  if(!allowed)return json({error:"RATE_LIMIT"},429);
  const {data:unit}=await sb.from("units").select("name").eq("id",profile.unit_id).single();
  const transport=nodemailer.createTransport({host:"smtp.gmail.com",port:465,secure:true,authMethod:"LOGIN",auth:{user:recipient,pass:password},connectionTimeout:10000,greetingTimeout:10000,socketTimeout:20000,disableFileAccess:true,disableUrlAccess:true});
  try{
    const result=await transport.sendMail({from:{name:"Pointage collectif",address:recipient},to:recipient,replyTo:{name:String(profile.full_name||"").replace(/[\r\n]/g," "),address:user.email},subject:"Pointage collectif — "+subject,text:`Message envoyé depuis l’application Pointage collectif.\n\nNom : ${profile.full_name||"Non renseigné"}\nUnité : ${unit?.name||"Non renseignée"}\nAdresse de réponse : ${user.email}\n\n${message}`});
    if(!result.accepted?.includes(recipient))return json({error:"SEND_FAILED"},502);
    return json({sent:true});
  }catch{console.error("CONTACT_ADMIN_SEND_FAILED");return json({error:"SEND_FAILED"},502);}
  finally{transport.close();}
});
