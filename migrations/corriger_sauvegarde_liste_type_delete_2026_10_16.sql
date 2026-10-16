-- Satisfy safe-update protection when replacing only the code-template snapshot.
CREATE OR REPLACE FUNCTION pointage_internal.save_code_template(p_revision bigint, p_codes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c jsonb;key uuid;keys uuid[]:='{}';pos integer:=0;revision_now bigint;
begin
 if auth.uid() is null or not public.pointage_is_admin() then raise exception 'Action réservée à l’administrateur' using errcode='42501';end if;
 if p_codes is null or jsonb_typeof(p_codes)<>'array' then raise exception 'Liste type invalide';end if;
 if jsonb_array_length(p_codes)=0 or jsonb_array_length(p_codes)>500 then raise exception 'La liste type doit contenir entre 1 et 500 codes';end if;
 if exists(select 1 from jsonb_array_elements(p_codes) v group by upper(btrim(v->>'code')) having count(*)>1) then raise exception 'Deux codes identiques sont présents';end if;
 perform pg_advisory_xact_lock(hashtextextended('pointage-code-template',0));
 select revision into revision_now from public.pointage_code_template_state where id for update;
 if p_revision is distinct from revision_now then raise exception 'La liste type a été modifiée ailleurs. Recharge-la avant de recommencer.';end if;
 for c in select value from jsonb_array_elements(p_codes) loop
  if nullif(btrim(c->>'code'),'') is null or nullif(btrim(c->>'label'),'') is null then raise exception 'Chaque code doit avoir un code et un libellé';end if;
  key:=nullif(c->>'catalogue_id','')::uuid;
  if key is null then insert into public.pointage_code_catalogue default values returning id into key;
  elsif not exists(select 1 from public.pointage_code_template where catalogue_id=key) then raise exception 'Code de référence inconnu';end if;
  if key=any(keys) then raise exception 'Code répété dans la liste';end if;
  keys:=array_append(keys,key);
  -- Validate before replacing the snapshot, keeping existing code identities.
  pos:=pos+1;
 end loop;
 delete from public.pointage_code_template where catalogue_id is not null;
 pos:=0;
 for c in select value from jsonb_array_elements(p_codes) loop
  pos:=pos+1;
  insert into public.pointage_code_template(catalogue_id,code,label,document,active,position)
  values(keys[pos],upper(btrim(c->>'code')),btrim(c->>'label'),coalesce(c->>'document',''),coalesce((c->>'active')::boolean,true),pos-1);
 end loop;
 update public.pointage_code_template_state set revision=revision+1 where id;
 return pointage_internal.get_code_template();
end;$function$
;