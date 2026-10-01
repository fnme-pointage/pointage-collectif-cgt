create table public.pointage_maintenance (
 id boolean primary key default true check(id),
 locked boolean not null default false,
 updated_at timestamptz not null default now()
);
insert into public.pointage_maintenance(id,locked) values(true,false);
alter table public.pointage_maintenance enable row level security;
revoke all on public.pointage_maintenance from public,anon,authenticated;
grant select,update on public.pointage_maintenance to authenticated;
create policy maintenance_read on public.pointage_maintenance for select to authenticated using ((select public.pointage_is_admin()) or (select public.current_user_is_active()));
create policy maintenance_admin_update on public.pointage_maintenance for update to authenticated using ((select public.pointage_is_admin())) with check ((select public.pointage_is_admin()));

create function pointage_internal.assert_saisie_allowed() returns void language plpgsql security definer set search_path='' as $$
declare paused boolean;
begin
 -- Share lock is held until the save transaction commits. The maintenance switch waits
 -- for in-flight saves before acknowledging activation.
 select locked into paused from public.pointage_maintenance where id=true for share;
 if paused is distinct from false and not public.pointage_is_admin() then
  raise exception 'Saisies bloquées pour maintenance. Tes modifications restent à enregistrer ; réessaie après la reprise.' using errcode='P0001';
 end if;
end;$$;
revoke all on function pointage_internal.assert_saisie_allowed() from public,anon;
grant execute on function pointage_internal.assert_saisie_allowed() to authenticated;

create function pointage_internal.guard_saisie_maintenance() returns trigger language plpgsql security definer set search_path='' as $$
begin
 -- Protect direct API requests and older clients as well as the application RPC.
 if auth.uid() is not null and not public.pointage_is_admin() then perform pointage_internal.assert_saisie_allowed();end if;
 if TG_OP='DELETE' then return old;end if;
 return new;
end;$$;
revoke all on function pointage_internal.guard_saisie_maintenance() from public,anon,authenticated;
create trigger entries_maintenance_guard before insert or update or delete on public.entries for each row execute function pointage_internal.guard_saisie_maintenance();
create trigger submissions_maintenance_guard before insert or update or delete on public.submissions for each row execute function pointage_internal.guard_saisie_maintenance();

create function public.pointage_set_maintenance(p_locked boolean) returns boolean language plpgsql security invoker set search_path='' as $$
begin
 if auth.uid() is null or not public.pointage_is_admin() then raise exception 'Action réservée à l’administrateur' using errcode='42501';end if;
 if p_locked is null then raise exception 'État de maintenance invalide';end if;
 update public.pointage_maintenance set locked=p_locked,updated_at=now() where id=true;
 if not found then raise exception 'État de maintenance indisponible';end if;
 return p_locked;
end;$$;
revoke all on function public.pointage_set_maintenance(boolean) from public,anon;
grant execute on function public.pointage_set_maintenance(boolean) to authenticated;

CREATE OR REPLACE FUNCTION public.pointage_save_entries(p_unit_id uuid, p_month_key text, p_entries jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_entries) e WHERE e->>'code_id' IS NULL OR e->>'hours' IS NULL OR (e->>'hours')::numeric<0) THEN
    RAISE EXCEPTION 'Chaque saisie doit avoir un code et des heures positives ou nulles';
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
  INSERT INTO public.entries(user_id,unit_id,month_key,code_id,hours)
    SELECT own_id,p_unit_id,p_month_key,(e->>'code_id')::bigint,round((e->>'hours')::numeric,2) FROM jsonb_array_elements(p_entries) e
    ON CONFLICT(user_id,month_key,code_id) DO UPDATE SET hours=excluded.hours,updated_at=now();
END;
$function$

