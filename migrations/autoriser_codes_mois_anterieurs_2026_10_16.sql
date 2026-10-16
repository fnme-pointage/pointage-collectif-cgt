-- Retroactive codes preserve prior historical pointages.
CREATE OR REPLACE FUNCTION pointage_internal.sync_codes(p_unit uuid, p_from text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m record; v record;
begin
 if auth.uid() is null or not (public.pointage_is_admin() or p_unit=public.pointage_user_unit() or public.pointage_manager_unit_allowed(p_unit)) then raise exception 'Accès refusé' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_unit::text,0));
 for m in select month_key from public.months where unit_id=p_unit and month_key>=p_from order by month_key loop
  if exists(select 1 from (select distinct on (catalogue_id) code,active from public.pointage_code_versions where unit_id=p_unit and effective_month<=m.month_key order by catalogue_id,effective_month desc) q group by upper(code) having count(*)>1) then raise exception 'Deux codes identiques pour le mois %',m.month_key;end if;
  for v in select distinct on(catalogue_id) * from public.pointage_code_versions where unit_id=p_unit and effective_month<=m.month_key order by catalogue_id,effective_month desc loop
   if m.month_key>=to_char(current_date,'YYYY-MM') and exists(select 1 from public.months mm where mm.unit_id=p_unit and mm.month_key=m.month_key and mm.is_open) then
    update public.month_codes set code=v.code,label=v.label,document=v.document,active=v.active where unit_id=p_unit and month_key=m.month_key and catalogue_id=v.catalogue_id;
   end if;
   if not exists(select 1 from public.month_codes existing where existing.unit_id=p_unit and existing.month_key=m.month_key and existing.catalogue_id=v.catalogue_id) then insert into public.month_codes(unit_id,month_key,catalogue_id,code,label,document,active) values(p_unit,m.month_key,v.catalogue_id,v.code,v.label,v.document,v.active);end if;
  end loop;
 end loop;
end;$function$
;

CREATE OR REPLACE FUNCTION public.pointage_save_catalogue(p_units uuid[], p_effective text, p_changes jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare u uuid;c jsonb;key uuid; boundary text;
begin
 if auth.uid() is null or not public.pointage_is_admin() then raise exception 'Action réservée à l’administrateur' using errcode='42501';end if;
 if p_effective !~ '^[1-9][0-9]{3}-(0[1-9]|1[0-2])$' or p_effective is null then raise exception 'Choisis un mois valide';end if;
 if coalesce(array_length(p_units,1),0)=0 or p_changes is null or jsonb_typeof(p_changes)<>'array' then raise exception 'Unités ou codes manquants';end if;
 foreach u in array p_units loop
  if not exists(select 1 from public.units where id=u and active and name<>'ADMIN') then raise exception 'Unité inconnue ou inactive';end if;
  perform pg_advisory_xact_lock(hashtextextended(u::text,0));
 end loop;
 for c in select value from jsonb_array_elements(p_changes) loop
  key:=nullif(c->>'catalogue_id','')::uuid;
  if key is null then insert into public.pointage_code_catalogue default values returning id into key;end if;
  foreach u in array p_units loop
   insert into public.pointage_code_versions(catalogue_id,unit_id,effective_month,code,label,document,active)
   values(key,u,p_effective,upper(btrim(c->>'code')),btrim(c->>'label'),coalesce(c->>'document',''),coalesce((c->>'active')::boolean,true))
   on conflict(catalogue_id,unit_id,effective_month) do update set code=excluded.code,label=excluded.label,document=excluded.document,active=excluded.active;
  end loop;
 end loop;
 foreach u in array p_units loop
  for boundary in select distinct effective_month from public.pointage_code_versions where unit_id=u and effective_month>=p_effective loop
   if exists(select 1 from (select distinct on(catalogue_id) code from public.pointage_code_versions where unit_id=u and effective_month<=boundary order by catalogue_id,effective_month desc) v group by upper(code) having count(*)>1) then raise exception 'Deux codes identiques à partir de %',boundary;end if;
  end loop;
  perform pointage_internal.sync_codes(u,p_effective);
 end loop;
end;$function$
;