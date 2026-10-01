-- Preserve the original entries and RPC before changing time precision.
create table if not exists pointage_private.entries_before_time_formats_20261001 as select * from public.entries;
alter table pointage_private.entries_before_time_formats_20261001 enable row level security;
revoke all on pointage_private.entries_before_time_formats_20261001 from public,anon,authenticated;
create table if not exists pointage_private.time_formats_rpc_backup as
 select pg_get_functiondef(oid) definition from pg_proc where pronamespace='public'::regnamespace and proname='pointage_save_entries';
alter table pointage_private.time_formats_rpc_backup enable row level security;
revoke all on pointage_private.time_formats_rpc_backup from public,anon,authenticated;
alter table public.entries add column duration_seconds bigint;
update public.entries set duration_seconds=round(hours*3600)::bigint;
alter table public.entries alter column duration_seconds set not null;
alter table public.entries add constraint entries_duration_seconds_check check(duration_seconds between 0 and 3599999964);
create or replace function pointage_internal.capture_entry_duration() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 if tg_op='INSERT' then
  if new.duration_seconds is null then new.duration_seconds=round(new.hours*3600)::bigint;end if;
 elsif new.duration_seconds is not distinct from old.duration_seconds and new.hours is distinct from old.hours then
  new.duration_seconds=round(new.hours*3600)::bigint;
 end if;
 new.hours=round(new.duration_seconds::numeric/3600,2);
 return new;
end;$$;
revoke all on function pointage_internal.capture_entry_duration() from public,anon,authenticated;
create trigger entries_duration_capture before insert or update on public.entries for each row execute function pointage_internal.capture_entry_duration();

CREATE OR REPLACE FUNCTION public.pointage_save_entries(p_unit_id uuid, p_month_key text, p_entries jsonb)
 RETURNS void LANGUAGE plpgsql SET search_path TO '' AS $$
DECLARE own_id uuid:=auth.uid(); month_open boolean;
BEGIN
  IF own_id IS NULL OR p_unit_id IS DISTINCT FROM public.pointage_user_unit() OR public.pointage_is_admin() THEN
    RAISE EXCEPTION 'Seul un utilisateur actif peut enregistrer son pointage dans son unité' USING ERRCODE='42501';
  END IF;
  PERFORM pointage_internal.assert_saisie_allowed();
  PERFORM pg_advisory_xact_lock(hashtextextended(p_unit_id::text,0));
  SELECT is_open INTO month_open FROM public.months WHERE unit_id=p_unit_id AND month_key=p_month_key;
  IF month_open IS DISTINCT FROM true THEN RAISE EXCEPTION 'Ce mois est fermé ou indisponible'; END IF;
  IF p_entries IS NULL OR jsonb_typeof(p_entries)<>'array' THEN RAISE EXCEPTION 'Saisies invalides'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_entries) e WHERE e->>'code_id' IS NULL OR e->>'hours' IS NULL OR
   (e->>'hours') !~ '^[0-9]+([.][0-9]+)?$' OR (e->>'hours')::numeric>999999.99 OR
   (e ? 'duration_seconds' AND (coalesce(e->>'duration_seconds','') !~ '^[0-9]+$' OR
    (e->>'duration_seconds')::numeric>3599999964 OR round((e->>'hours')::numeric*3600)<>(e->>'duration_seconds')::numeric))) THEN
    RAISE EXCEPTION 'Chaque saisie doit avoir un code et une durée valide, positive ou nulle';
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(p_entries)) <>
     (SELECT count(DISTINCT (e->>'code_id')::bigint) FROM jsonb_array_elements(p_entries) e) THEN
    RAISE EXCEPTION 'Un même code ne peut apparaître qu’une fois dans le mois';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_entries) e WHERE NOT EXISTS(
    SELECT 1 FROM public.month_codes c WHERE c.id=(e->>'code_id')::bigint AND c.unit_id=p_unit_id AND c.month_key=p_month_key
      AND (c.active OR EXISTS(SELECT 1 FROM public.entries old WHERE old.user_id=own_id AND old.unit_id=p_unit_id AND old.month_key=p_month_key AND old.code_id=c.id))
  )) THEN RAISE EXCEPTION 'Un code ne correspond pas au mois ou à l’unité'; END IF;
  DELETE FROM public.entries WHERE user_id=own_id AND unit_id=p_unit_id AND month_key=p_month_key AND code_id NOT IN (SELECT (e->>'code_id')::bigint FROM jsonb_array_elements(p_entries) e);
  INSERT INTO public.entries(user_id,unit_id,month_key,code_id,hours,duration_seconds)
    SELECT own_id,p_unit_id,p_month_key,(e->>'code_id')::bigint,round((e->>'hours')::numeric,2),
      coalesce((e->>'duration_seconds')::bigint,
       (select old.duration_seconds from public.entries old where old.user_id=own_id and old.unit_id=p_unit_id and old.month_key=p_month_key and old.code_id=(e->>'code_id')::bigint and old.hours=round((e->>'hours')::numeric,2)),
       round((e->>'hours')::numeric*3600)::bigint)
    FROM jsonb_array_elements(p_entries) e
    ON CONFLICT(user_id,month_key,code_id) DO UPDATE SET hours=excluded.hours,duration_seconds=excluded.duration_seconds,updated_at=now();
END;$$;
