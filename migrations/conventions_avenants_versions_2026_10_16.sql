create table if not exists public.pointage_convention_versions (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id) on delete cascade,
 valid_from date not null,
 valid_until date not null,
 effective_from date not null,
 reason text,
 created_at timestamptz not null default now(),
 check(valid_until >= valid_from and effective_from between valid_from and valid_until),
 unique(user_id,effective_from)
);
create table if not exists public.pointage_convention_version_codes (
 version_id uuid not null references public.pointage_convention_versions(id) on delete cascade,
 code text not null,
 hours numeric(12,2) not null check(hours >= 0),
 primary key(version_id,code)
);
alter table public.pointage_convention_versions enable row level security;
alter table public.pointage_convention_version_codes enable row level security;
create policy convention_version_read on public.pointage_convention_versions for select to authenticated using (
 user_id=auth.uid() or exists (
 select 1 from public.profiles caller join public.profiles target on target.id=user_id
 where caller.id=auth.uid() and caller.active and
 (caller.is_admin or (caller.is_unit_manager and caller.unit_id=target.unit_id)
 or (caller.is_division_manager and exists(select 1 from public.units u where u.id=target.unit_id and u.division_id=caller.managed_division_id)))
 ));
create policy convention_version_insert on public.pointage_convention_versions for insert to authenticated with check(user_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.active));
create policy convention_code_read on public.pointage_convention_version_codes for select to authenticated using(exists(select 1 from public.pointage_convention_versions v where v.id=version_id));
create policy convention_code_insert on public.pointage_convention_version_codes for insert to authenticated with check(exists(select 1 from public.pointage_convention_versions v where v.id=version_id and v.user_id=auth.uid()));
grant select,insert on public.pointage_convention_versions,public.pointage_convention_version_codes to authenticated;
