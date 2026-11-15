-- Defence in depth for direct Data API access to availability table.
-- The UI uses an RPC, but authenticated users may have table-write grants.
create or replace function pointage_private.availability_stamp()
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
  if not pointage_private.availability_can_manage(new.unit_id) then
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
