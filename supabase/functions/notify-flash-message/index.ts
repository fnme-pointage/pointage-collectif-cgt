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
  const appPassword = password.replace(/\s/g, "");
  if (!/^[a-z]{16}$/.test(appPassword)) return Response.json({error:"APP_PASSWORD_FORMAT_INVALID"}, {status:400});
  const transport = nodemailer.createTransport({
    host:"smtp.gmail.com", port:465, secure:true, authMethod:"LOGIN",
    auth:{user:recipient,pass:appPassword},
    connectionTimeout:10000,greetingTimeout:10000,socketTimeout:20000,
    disableFileAccess:true,disableUrlAccess:true,
  });
  const {data: jobs,error: claimError}=await sb.rpc("pointage_claim_flash_notifications",{p_token:token});
  if (claimError) {transport.close();return Response.json({error:"QUEUE_UNAVAILABLE"},{status:500});}
  let sent=0,failed=0;
  try {
    for(const job of jobs || []) {
      let success=false,errorCode="";
      try {
        const result = await transport.sendMail({from:{name:"Administrateur — Pointage collectif",address:recipient},to:job.email,
          messageId:`<flash-${job.message_id}-${job.user_id}@pointage-collectif.local>`,
          subject:"Pointage collectif — " + job.title,
          text:`${job.title}\n\n${job.body}\n\nAccéder à Pointage collectif :\n${appUrl}\n\nL’administrateur de Pointage collectif`,
          html:`<h2>${escapeHtml(job.title)}</h2><p>${escapeHtml(job.body).replace(/\n/g,"<br>")}</p><p><a href="${appUrl}">Accéder à Pointage collectif</a></p><p>L’administrateur de Pointage collectif</p>`});
        if (!result.accepted?.some((address: string) => address.toLowerCase() === job.email.toLowerCase())) throw {code:"RECIPIENT_REJECTED"};
        success=true;sent++;
      }catch(error){errorCode=String((error as {code?:string}).code || "SMTP_ERROR").replace(/[^A-Z0-9_]/g, "").slice(0,40);failed++;}
      const {error}=await sb.rpc("pointage_finish_flash_notification",{p_token:token,p_id:job.id,p_claim:job.claim_id,p_sent:success,p_error:errorCode});
      if(error) console.error("NOTIFICATION_STATUS_UPDATE_FAILED");
    }
    return Response.json({sent,failed});
  }finally{transport.close();}
});
