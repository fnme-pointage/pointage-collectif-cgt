-- Isolate annual availability helpers from preexisting private functions.
create schema if not exists pointage_availability_private;
revoke all on schema pointage_availability_private from public, anon;
grant usage on schema pointage_availability_private to authenticated;

alter function pointage_private.availability_can_manage(uuid) set schema pointage_availability_private;
alter function pointage_private.availability_stamp() set schema pointage_availability_private;
alter function pointage_private.availability_audit_change() set schema pointage_availability_private;

create or replace function pointage_availability_private.availability_stamp()
returns trigger language plpgsql security invoker set search_path = ''
as $fn$
begin
  if tg_op = 'UPDATE' and
    (new.unit_id is distinct from old.unit_id
      or new.year is distinct from old.year
      or new.catalogue_id is distinct from old.catalogue_id) then
    raise exception 'L''unité, l''année et le code ne peuvent pas être modifiés.'
      using errcode='22023';
  end if;
  if not pointage_availability_private.availability_can_manage(new.unit_id) then
    raise exception 'Droits insuffisants pour cette unité.' using errcode='42501';
  end if;
  if not exists (
    select 1 from public.month_codes mc
    where mc.unit_id = new.unit_id and mc.catalogue_id = new.catalogue_id
  ) and not exists (
    select 1 from public.pointage_code_versions cv
    where cv.unit_id = new.unit_id and cv.catalogue_id = new.catalogue_id
  ) then
    raise exception 'Code non disponible dans cette unité.' using errcode='22023';
  end if;
  new.updated_by = (select auth.uid());
  new.updated_at = now();
  if tg_op = 'UPDATE' then
    new.revision = old.revision + 1;
  else
    new.revision = 1;
  end if;
  return new;
end;
$fn$;

create or replace function public.pointage_save_annual_code_availability(
 p_unit_id uuid, p_year integer, p_changes jsonb)
returns integer language plpgsql security invoker set search_path = ''
as $fn$
declare
 item jsonb;
 code_uuid uuid;
 seconds_value bigint;
 expected_revision integer;
 effected integer;
 changed integer := 0;
begin
 if not pointage_availability_private.availability_can_manage(p_unit_id) then
   raise exception 'Droits insuffisants pour cette unité.' using errcode='42501';
 end if;
 if p_year not between 2000 and 2100 then
   raise exception 'Année invalide.' using errcode='22023';
 end if;
 if jsonb_typeof(p_changes) is distinct from 'array' or jsonb_array_length(p_changes) > 200 then
   raise exception 'Liste de modifications invalide.' using errcode='22023';
 end if;
 if exists (select 1 from jsonb_array_elements(p_changes) e
            group by e->>'catalogue_id' having count(*) > 1) then
   raise exception 'Un même code est présent plusieurs fois.' using errcode='22023';
 end if;
 for item in select value from jsonb_array_elements(p_changes) loop
   code_uuid := (item->>'catalogue_id')::uuid;
   expected_revision := nullif(item->>'revision','')::integer;
   seconds_value := nullif(item->>'available_seconds','')::bigint;
   if code_uuid is null then raise exception 'Code manquant.' using errcode='22023'; end if;
   if seconds_value is not null and (seconds_value < 0 or seconds_value > 3600000000) then
     raise exception 'Le nombre d’heures est hors limites.' using errcode='22023';
   end if;
   if not exists (
      select 1 from public.month_codes mc
       where mc.unit_id = p_unit_id and mc.catalogue_id = code_uuid
     ) and not exists (
      select 1 from public.pointage_code_versions cv
       where cv.unit_id = p_unit_id and cv.catalogue_id = code_uuid
     ) then
     raise exception 'Code non disponible dans cette unité.' using errcode='22023';
   end if;
   if expected_revision is null then
      if seconds_value is not null then
        insert into public.pointage_annual_code_availability
          (unit_id, year, catalogue_id, available_seconds)
        values (p_unit_id, p_year, code_uuid, seconds_value);
        changed := changed + 1;
      end if;
   else
      if seconds_value is null then
        delete from public.pointage_annual_code_availability
          where unit_id = p_unit_id and year = p_year
            and catalogue_id = code_uuid and revision = expected_revision;
      else
        update public.pointage_annual_code_availability
          set available_seconds = seconds_value
          where unit_id = p_unit_id and year = p_year
            and catalogue_id = code_uuid and revision = expected_revision;
      end if;
      get diagnostics effected = row_count;
      if effected <> 1 then
        raise exception 'Une disponibilité a changé entre-temps : recharge la page.'
          using errcode='40001';
      end if;
      changed := changed + 1;
   end if;
 end loop;
 return changed;
end;
$fn$;
revoke all on function public.pointage_save_annual_code_availability(uuid,integer,jsonb) from public, anon;
grant execute on function public.pointage_save_annual_code_availability(uuid,integer,jsonb) to authenticated;


-- Return historical private schema to original access boundary.
revoke usage on schema pointage_private from authenticated;
