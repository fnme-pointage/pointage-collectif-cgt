-- Preference de report des codes actifs du mois precedent (heures jamais transferees).
alter table public.profiles add column if not exists carry_codes_next_month boolean not null default true;

create or replace function public.pointage_set_carry_codes(p_user_id uuid,p_enabled boolean)
returns void language plpgsql security definer set search_path to ''
as $$
begin
 if auth.uid() is null or p_enabled is null then raise exception 'Acces refuse' using errcode='42501'; end if;
 if not exists (
  select 1 from public.profiles caller join public.profiles target on target.id=p_user_id
  where caller.id=auth.uid() and caller.active and
   (caller.id=target.id or caller.is_admin or (not target.is_admin and
    ((caller.is_unit_manager and caller.unit_id=target.unit_id)
     or (caller.is_division_manager and exists
       (select 1 from public.units u where u.id=target.unit_id and u.division_id=caller.managed_division_id)))))
 ) then raise exception 'Droits insuffisants' using errcode='42501'; end if;
 update public.profiles set carry_codes_next_month=p_enabled where id=p_user_id;
end $$;
revoke all on function public.pointage_set_carry_codes(uuid,boolean) from public,anon;
grant execute on function public.pointage_set_carry_codes(uuid,boolean) to authenticated;