create table if not exists public.pointage_convention_hours (
 user_id uuid not null references public.profiles(id) on delete cascade,
 year integer not null check(year between 2020 and 2200),
 code text not null,
 hours numeric(12,2) not null check(hours>=0),
 updated_at timestamptz not null default now(),
 primary key(user_id,year,code)
);
alter table public.pointage_convention_hours enable row level security;
create policy convention_read on public.pointage_convention_hours for select to authenticated
 using (user_id=auth.uid() or exists (
 select 1 from public.profiles caller join public.profiles person on person.id=pointage_convention_hours.user_id
 where caller.id=auth.uid() and caller.active and
 (caller.is_admin or
 (caller.is_unit_manager and caller.unit_id=person.unit_id)
 or (caller.is_division_manager and exists(select 1 from public.units u where u.id=person.unit_id and u.division_id=caller.managed_division_id)))));
create policy convention_insert on public.pointage_convention_hours for insert to authenticated
 with check(user_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.active));
create policy convention_update on public.pointage_convention_hours for update to authenticated
 using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy convention_delete on public.pointage_convention_hours for delete to authenticated using(user_id=auth.uid());
grant select,insert,update,delete on public.pointage_convention_hours to authenticated;