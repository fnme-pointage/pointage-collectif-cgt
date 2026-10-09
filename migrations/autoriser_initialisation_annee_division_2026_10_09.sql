-- Autoriser initialisation des années pour une unité administrée au sein de la division.
CREATE OR REPLACE FUNCTION pointage_internal.ensure_year(p_unit uuid, p_year integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not (public.pointage_is_admin() or p_unit=public.pointage_user_unit() or public.pointage_manager_unit_allowed(p_unit)) then raise exception 'Accès refusé' using errcode='42501';end if;
 if p_year<1900 or p_year>9999 or p_year is null then raise exception 'Année invalide';end if;
 if not exists(select 1 from public.units where id=p_unit and active and name<>'ADMIN') then return;end if;
 perform pg_advisory_xact_lock(hashtextextended(p_unit::text,0));
 if not exists(select 1 from public.pointage_code_versions where unit_id=p_unit) then
  insert into public.pointage_code_versions(catalogue_id,unit_id,effective_month,code,label,document,active)
  select catalogue_id,p_unit,'1900-01',code,label,document,active from public.pointage_code_template order by position;
 end if;
 insert into public.months(unit_id,month_key,is_open) select p_unit,p_year::text||'-'||lpad(n::text,2,'0'),true from generate_series(1,12) n on conflict do nothing;
 -- Never update a pre-existing past month when an old year is opened.
 perform pointage_internal.sync_codes(p_unit,greatest(p_year::text||'-01',to_char(current_date,'YYYY-MM')));
 -- Fill empty historical months while preserving existing snapshots.
 insert into public.month_codes(unit_id,month_key,catalogue_id,code,label,document,active)
 select p_unit,m.month_key,v.catalogue_id,v.code,v.label,v.document,v.active from public.months m
 cross join lateral (select distinct on(catalogue_id) * from public.pointage_code_versions where unit_id=p_unit and effective_month<=m.month_key order by catalogue_id,effective_month desc) v
 where m.unit_id=p_unit and m.month_key like p_year::text||'-%'
 and not exists(select 1 from public.month_codes c where c.unit_id=p_unit and c.month_key=m.month_key)
 on conflict do nothing;
end;$function$
;
