import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import nodemailer from "npm:nodemailer@8.0.11";

const recipient = "fnme.pointage@gmail.com";
const appUrl = "https://fnme-pointage.github.io/pointage-collectif-cgt/";
const escapeHtml = (value: string) => String(value || "").replace(/[&<>"']/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]!));

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const token = request.headers.get("x-pointage-notification-token");
  if (!token) return new Response("Unauthorized", { status: 401 });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {auth:{persistSession:false,autoRefreshToken:false}});
  const {data: allowed, error: authError} = await sb.rpc("pointage_notification_authorized", {p_token:token});
  if (authError || !allowed) return new Response("Unauthorized", { status: 401 });
  const password = Deno.env.get("POINTAGE_GMAIL_APP_PASSWORD");
  if (!password) return Response.json({error:"SMTP_NOT_CONFIGURED"}, {status:503});
  const transport = nodemailer.createTransport({
    host:"smtp.gmail.com", port:465, secure:true,
    auth:{user:recipient,pass:password.replace(/\s/g, "")},
    connectionTimeout:10000,greetingTimeout:10000,socketTimeout:20000,
    disableFileAccess:true,disableUrlAccess:true,
  });
  let body: {test?: boolean} = {};
  try { body = await request.json(); } catch { /* ordinary dispatch */ }
  if (body.test === true) {
    try {
      await transport.sendMail({from:{name:"Pointage collectif",address:recipient},to:recipient,
        subject:"Test — notifications d’inscription Pointage collectif",
        text:"Les notifications sont configurées. Tu recevras un mail lorsqu’un nouvel inscrit aura confirmé son adresse et attendra l’activation de son compte.\n\n"+appUrl});
      return Response.json({sent:1,test:true});
    } catch(error) { const e=error as {code?:string;responseCode?:number;command?:string;name?:string;response?:string}; return Response.json({error:"SMTP_TEST_FAILED",reason:/Application-specific password required/i.test(e.response||"")?"APP_PASSWORD_REQUIRED":/log in.*web browser/i.test(e.response||"")?"GOOGLE_ACCOUNT_VERIFICATION_REQUIRED":"AUTHENTICATION_FAILED",code:String(e.code||e.name||"UNKNOWN").replace(/[^A-Za-z0-9_]/g,"").slice(0,40),smtpStatus:Number(e.responseCode)||null,command:String(e.command||"").replace(/[^A-Z]/g,"").slice(0,20)},{status:502}); }
    finally { transport.close(); }
  }
  const {data: jobs,error: claimError}=await sb.rpc("pointage_claim_signup_notifications",{p_token:token});
  if (claimError) {transport.close();return Response.json({error:"QUEUE_UNAVAILABLE"},{status:500});}
  let sent=0,failed=0;
  try {
    for(const job of jobs || []) {
      let success=false,errorCode="";
      try {
        const name=job.full_name || "Nom non renseigné",unit=job.requested_unit || "Non renseignée";
        await transport.sendMail({from:{name:"Pointage collectif",address:recipient},to:recipient,
          messageId:`<signup-${job.user_id}@pointage-collectif.local>`,
          subject:"Pointage collectif — nouvel inscrit à activer",
          text:`Un nouvel inscrit a confirmé son adresse e-mail par code et attend l’activation de son compte.\n\nNom : ${name}\nUnité demandée : ${unit}\n\nConnecte-toi à l’application, puis ouvre Utilisateurs dans l’onglet ADMIN pour affecter l’unité et activer le compte :\n${appUrl}`,
          html:`<h2>Nouvel inscrit à activer</h2><p>Son adresse e-mail est confirmée.</p><p><strong>Nom :</strong> ${escapeHtml(name)}<br><strong>Unité demandée :</strong> ${escapeHtml(unit)}</p><p><a href="${appUrl}">Ouvrir Pointage collectif</a>, puis Utilisateurs dans l’onglet ADMIN pour affecter l’unité et activer le compte.</p>`});
        success=true;sent++;
      }catch(error){errorCode=String((error as {code?:string}).code || "SMTP_ERROR").replace(/[^A-Z0-9_]/g, "").slice(0,40);failed++;}
      const {error}=await sb.rpc("pointage_finish_signup_notification",{p_token:token,p_id:job.id,p_claim:job.claim_id,p_sent:success,p_error:errorCode});
      if(error) console.error("NOTIFICATION_STATUS_UPDATE_FAILED");
    }
    return Response.json({sent,failed});
  }finally{transport.close();}
});
