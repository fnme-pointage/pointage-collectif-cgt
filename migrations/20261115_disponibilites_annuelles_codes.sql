-- Pointage Collectif CGT: annual code availability per unit (additive migration).
-- No change to entries/months/month_codes or their existing policies.
create schema if not exists pointage_private;
revoke all on schema pointage_private from public;
grant usage on schema pointage_private to authenticated;

create table if not exists public.pointage_annual_code_availability (
  unit_id uuid not null references public.units(id),
  year integer not null check (year between 2000 and 2100),
  catalogue_id uuid not null references public.pointage_code_catalogue(id),
  available_seconds bigint not null check (available_seconds between 0 and 3600000000),
  revision integer not null default 1 check (revision >= 1),
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  primary key (unit_id, year, catalogue_id)
);

create table if not exists public.pointage_annual_code_availability_audit (
  id bigint generated always as identity primary key,
  unit_id uuid not null references public.units(id),
  year integer not null,
  catalogue_id uuid not null references public.pointage_code_catalogue(id),
  old_seconds bigint,
  new_seconds bigint,
  changed_by uuid,
  changed_at timestamptz not null default now(),
  operation text not null check (operation in ('INSERT','UPDATE','DELETE'))
);

create index if not exists pointage_availability_audit_lookup
 on public.pointage_annual_code_availability_audit (unit_id, year, changed_at desc);

create or replace function pointage_private.availability_can_manage(p_unit_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $fn$
 select exists(
   select 1 from public.units u
   join public.profiles p on p.id = (select auth.uid())
   where u.id = p_unit_id and u.active and u.name <> 'ADMIN' and p.active
     and (p.is_admin
       or (p.is_unit_manager and p.unit_id = u.id)
       or (p.is_division_manager and p.managed_division_id = u.division_id
           and p.managed_division_id is not null
           and exists (select 1 from public.units own
               where own.id = p.unit_id and own.division_id = p.managed_division_id)))
 );
$fn$;
revoke all on function pointage_private.availability_can_manage(uuid) from public;
grant execute on function pointage_private.availability_can_manage(uuid) to authenticated;

alter table public.pointage_annual_code_availability enable row level security;
alter table public.pointage_annual_code_availability_audit enable row level security;

create policy "availability_read_managers"
 on public.pointage_annual_code_availability for select to authenticated
 using (pointage_private.availability_can_manage(unit_id));
create policy "availability_add_managers"
 on public.pointage_annual_code_availability for insert to authenticated
 with check (pointage_private.availability_can_manage(unit_id));
create policy "availability_change_managers"
 on public.pointage_annual_code_availability for update to authenticated
 using (pointage_private.availability_can_manage(unit_id))
 with check (pointage_private.availability_can_manage(unit_id));
create policy "availability_remove_managers"
 on public.pointage_annual_code_availability for delete to authenticated
 using (pointage_private.availability_can_manage(unit_id));
create policy "availability_audit_read_managers"
 on public.pointage_annual_code_availability_audit for select to authenticated
 using (pointage_private.availability_can_manage(unit_id));

revoke all on public.pointage_annual_code_availability from public, anon;
revoke all on public.pointage_annual_code_availability_audit from public, anon;
grant select, insert, update, delete on public.pointage_annual_code_availability to authenticated;
grant select on public.pointage_annual_code_availability_audit to authenticated;

create or replace function pointage_private.availability_stamp()
returns trigger language plpgsql security invoker set search_path = ''
as $fn$
begin
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

create or replace function pointage_private.availability_audit_change()
returns trigger language plpgsql security definer set search_path = ''
as $fn$
begin
  insert into public.pointage_annual_code_availability_audit
    (unit_id, year, catalogue_id, old_seconds, new_seconds, changed_by, operation)
  values (
    coalesce(new.unit_id, old.unit_id),
    coalesce(new.year, old.year),
    coalesce(new.catalogue_id, old.catalogue_id),
    case when tg_op = 'INSERT' then null else old.available_seconds end,
    case when tg_op = 'DELETE' then null else new.available_seconds end,
    (select auth.uid()), tg_op
  );
  return coalesce(new, old);
end;
$fn$;
revoke all on function pointage_private.availability_stamp() from public;
revoke all on function pointage_private.availability_audit_change() from public;
drop trigger if exists availability_stamp on public.pointage_annual_code_availability;
create trigger availability_stamp before insert or update on public.pointage_annual_code_availability
 for each row execute function pointage_private.availability_stamp();
drop trigger if exists availability_audit_change on public.pointage_annual_code_availability;
create trigger availability_audit_change after insert or update or delete on public.pointage_annual_code_availability
 for each row execute function pointage_private.availability_audit_change();

-- Atomic batch, RLS protected, optimistic version checks: no partial writes.
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
 if not pointage_private.availability_can_manage(p_unit_id) then
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
