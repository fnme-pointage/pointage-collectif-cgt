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
 for m in select month_key from public.months where unit_id=p_unit and month_key>=greatest(p_from,to_char(current_date,'YYYY-MM')) and is_open order by month_key loop
  if exists(select 1 from (select distinct on (catalogue_id) code,active from public.pointage_code_versions where unit_id=p_unit and effective_month<=m.month_key order by catalogue_id,effective_month desc) q group by upper(code) having count(*)>1) then raise exception 'Deux codes identiques pour le mois %',m.month_key;end if;
  for v in select distinct on(catalogue_id) * from public.pointage_code_versions where unit_id=p_unit and effective_month<=m.month_key order by catalogue_id,effective_month desc loop
   update public.month_codes set code=v.code,label=v.label,document=v.document,active=v.active where unit_id=p_unit and month_key=m.month_key and catalogue_id=v.catalogue_id;
   if not found then insert into public.month_codes(unit_id,month_key,catalogue_id,code,label,document,active) values(p_unit,m.month_key,v.catalogue_id,v.code,v.label,v.document,v.active);end if;
  end loop;
 end loop;
end;$function$
;
