CREATE OR REPLACE FUNCTION pointage_internal.save_national_codes(p_revision bigint, p_codes jsonb, p_apply_units boolean, p_effective text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare before_codes jsonb;snapshot jsonb;changes jsonb;u record;applied integer:=0;
begin
 if auth.uid() is null or not public.pointage_is_admin() then raise exception 'Action réservée à l’administrateur' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('pointage-code-template',0));
 before_codes:=pointage_internal.get_code_template()->'codes';
 snapshot:=pointage_internal.save_code_template(p_revision,p_codes);
 select coalesce(jsonb_agg(c),'[]'::jsonb) into changes
 from jsonb_array_elements(snapshot->'codes') c
 where not exists(select 1 from jsonb_array_elements(before_codes) old
   where old->>'catalogue_id'=c->>'catalogue_id'
   and old->>'code'=c->>'code' and old->>'label'=c->>'label'
   and old->>'document'=c->>'document' and old->>'active'=c->>'active');
 if p_apply_units then
  if p_effective is null or p_effective !~ '^[1-9][0-9]{3}-(0[1-9]|1[0-2])$' then raise exception 'Choisis un mois valide';end if;
  if jsonb_array_length(changes)>0 then
   for u in select id,name from public.units where active and name<>'ADMIN' order by id loop
    begin
     perform public.pointage_save_catalogue(array[u.id],p_effective,changes);
    exception when others then
     raise exception 'Application nationale annulée pour toutes les unités : conflit dans % (%). Aucun catalogue ni pointage n’a été modifié.',u.name,sqlerrm;
    end;
    applied:=applied+1;
   end loop;
  end if;
 end if;
 return snapshot||jsonb_build_object('applied_units',applied,'changed_codes',jsonb_array_length(changes));
end;$function$
;