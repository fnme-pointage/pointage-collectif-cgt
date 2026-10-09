import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const allowedOrigin="https://fnme-pointage.github.io";
const cors={"Access-Control-Allow-Origin":allowedOrigin,"Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
const json=(body:Record<string,unknown>,status=200)=>Response.json(body,{status,headers:cors});

Deno.serve(async(request:Request)=>{
  const origin=request.headers.get("origin");
  if(origin && origin!==allowedOrigin)return json({error:"ORIGIN_DENIED"},403);
  if(request.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
  if(request.method!=="POST")return json({error:"METHOD_NOT_ALLOWED"},405);

  const jwt=request.headers.get("authorization")?.match(/^Bearer (.+)$/i)?.[1];
  if(!jwt)return json({error:"AUTH_REQUIRED"},401);
  const admin=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{
    auth:{persistSession:false,autoRefreshToken:false}
  });
  const {data:auth,error:authError}=await admin.auth.getUser(jwt);
  if(authError||!auth.user)return json({error:"AUTH_REQUIRED"},401);
  let input:Record<string,unknown>;
  try{const body=await request.text();if(body.length>1000)return json({error:"INVALID_INPUT"},400);input=JSON.parse(body);}
  catch{return json({error:"INVALID_INPUT"},400);}
  const userId=input?.user_id;
  if(typeof userId!=="string"||!/^[0-9a-f-]{36}$/i.test(userId))return json({error:"INVALID_INPUT"},400);
  if(userId===auth.user.id)return json({error:"SELF_DELETE_FORBIDDEN"},403);

  const [{data:caller,error:ce},{data:target,error:te}]=await Promise.all([
    admin.from("profiles").select("id,active,is_admin,is_unit_manager,is_division_manager,managed_division_id,unit_id").eq("id",auth.user.id).single(),
    admin.from("profiles").select("id,is_admin,is_unit_manager,unit_id").eq("id",userId).single()
  ]);
  if(ce||te||!caller||!target)return json({error:"ACCOUNT_NOT_FOUND"},404);
  if(!caller.active||(!caller.is_admin&&!caller.is_unit_manager&&!caller.is_division_manager))return json({error:"NOT_AUTHORIZED"},403);
  if(!caller.is_admin){
    if(target.is_admin)return json({error:"NOT_AUTHORIZED"},403);
    const ownUnit=caller.is_unit_manager&&caller.unit_id===target.unit_id;
    let divisionUnit=false;
    if(caller.is_division_manager&&caller.managed_division_id){
      const {data:units,error:ue}=await admin.from("units").select("id,division_id").in("id",[caller.unit_id,target.unit_id]);
      if(ue)return json({error:"SCOPE_UNAVAILABLE"},503);
      divisionUnit=units?.some(u=>u.id===caller.unit_id&&u.division_id===caller.managed_division_id)&&
        units?.some(u=>u.id===target.unit_id&&u.division_id===caller.managed_division_id);
    }
    if(!ownUnit&&!divisionUnit)return json({error:"NOT_AUTHORIZED"},403);
  }
  if(target.is_admin){
    if(!caller.is_admin)return json({error:"NOT_AUTHORIZED"},403);
    const {count,error}=await admin.from("profiles").select("id",{count:"exact",head:true}).eq("is_admin",true).eq("active",true);
    if(error)return json({error:"CHECK_UNAVAILABLE"},503);
    if((count||0)<=1)return json({error:"LAST_ADMIN_FORBIDDEN"},403);
  }

  if(input.confirm_permanent_deletion!==true)return json({error:"CONFIRMATION_REQUIRED"},400);
  // La suppression auth.users cascade vers profiles, entries, submissions et notifications.
  const {error:deleteError}=await admin.auth.admin.deleteUser(userId);
  if(deleteError){
    console.error("DELETE_MANAGED_USER_FAILED",deleteError.message);
    return json({error:"DELETE_FAILED"},500);
  }
  return json({ok:true});
});