import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const appOrigin="https://fnme-pointage.github.io";
const appUrl="https://fnme-pointage.github.io/pointage-collectif-cgt/";
const cors={"Access-Control-Allow-Origin":appOrigin,"Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
const json=(body:Record<string,unknown>,status=200)=>Response.json(body,{status,headers:cors});

Deno.serve(async(request:Request)=>{
  const origin=request.headers.get("origin");
  if(origin && origin!==appOrigin)return json({error:"ORIGIN_DENIED"},403);
  if(request.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
  if(request.method!=="POST")return json({error:"METHOD_NOT_ALLOWED"},405);
  const jwt=request.headers.get("authorization")?.match(/^Bearer (.+)$/i)?.[1];
  if(!jwt)return json({error:"AUTH_REQUIRED"},401);
  const sb=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:auth,error:authError}=await sb.auth.getUser(jwt);
  if(authError||!auth.user)return json({error:"AUTH_REQUIRED"},401);
  const {data:caller,error:callerError}=await sb.from("profiles").select("id,active,is_admin,is_unit_manager,unit_id").eq("id",auth.user.id).single();
  if(callerError||!caller?.active||(!caller.is_admin&&!caller.is_unit_manager))return json({error:"NOT_AUTHORIZED"},403);
  let raw:Record<string,unknown>;
  try{const source=await request.text();if(source.length>5000)return json({error:"INVALID_INPUT"},400);raw=JSON.parse(source);}catch{return json({error:"INVALID_INPUT"},400);}
  if(!raw||typeof raw!=="object"||Array.isArray(raw))return json({error:"INVALID_INPUT"},400);
  if(typeof raw.full_name!=="string"||typeof raw.email!=="string"||typeof raw.unit_id!=="string"||typeof raw.role!=="string")
    return json({error:"INVALID_INPUT"},400);
  const name=raw.full_name.trim(),email=raw.email.trim().toLowerCase(),unitId=raw.unit_id,role=raw.role;
  if(name.length<1||name.length>150||email.length>320||!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
    ||!/^[a-f0-9-]{36}$/i.test(unitId)||!["user","manager","admin"].includes(role))
    return json({error:"INVALID_INPUT"},400);
  const {data:unit,error:unitError}=await sb.from("units").select("id,name,active").eq("id",unitId).single();
  if(unitError||!unit?.active)return json({error:"INVALID_UNIT"},400);
  const national=unit.name==="ADMIN";
  if((role==="admin")!==national)return json({error:"INVALID_ROLE_UNIT"},403);
  if(!caller.is_admin){
    if(unitId!==caller.unit_id||national||role==="admin")return json({error:"NOT_AUTHORIZED"},403);
  }
  // Seul le serveur crée le compte, avec une invitation de définition de mot de passe.
  // Le compte reste affecté à l'unité sélectionnée, sans passer par une session privilégiée dans le navigateur.
  const {data:invite,error:inviteError}=await sb.auth.admin.inviteUserByEmail(email,{
    redirectTo:appUrl,
    data:{full_name:name,unit_id:unitId}
  });
  if(inviteError||!invite?.user?.id){
    console.error("INVITE_MANAGED_USER_FAILED",inviteError?.message);
    return json({error:"INVITATION_FAILED",details:inviteError?.message||"Invitation impossible"},400);
  }
  const userId=invite.user.id;
  const {data:updated,error:updateError}=await sb.from("profiles")
    .update({full_name:name,email,unit_id:unitId,requested_unit_id:unitId,
      active:true,is_admin:role==="admin",is_unit_manager:role==="manager"})
    .eq("id",userId).select("id").single();
  if(updateError||!updated){
    console.error("MANAGED_USER_PROFILE_FAILED",updateError?.message,userId);
    // La personne peut recevoir son invitation : ne pas exposer le compte non affecté.
    // S'il s'agit bien du compte nouvellement invité, l'annuler pour éviter un profil orphelin.
    const {error:deleteError}=await sb.auth.admin.deleteUser(userId);
    if(deleteError)console.error("MANAGED_USER_CLEANUP_FAILED",userId,deleteError.message);
    return json({error:"PROFILE_SETUP_FAILED"},500);
  }
  return json({ok:true,id:userId});
});