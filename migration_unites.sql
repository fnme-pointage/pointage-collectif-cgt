-- À exécuter une seule fois dans Supabase SQL Editor, avant de publier la nouvelle interface.
-- Les lignes existantes sont rattachées à l'ULM. Exécuter dans une transaction.
begin;

create extension if not exists pgcrypto;
create table public.units (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true,
  constraint units_name_nonempty check (length(trim(name)) between 1 and 100)
);
insert into public.units(name) values ('ULM'), ('UFPI');

alter table public.profiles add column unit_id uuid;
alter table public.months add column unit_id uuid;
alter table public.month_codes add column unit_id uuid;
alter table public.entries add column unit_id uuid;
alter table public.submissions add column unit_id uuid;

update public.profiles set unit_id=(select id from public.units where name='ULM');
update public.months set unit_id=(select id from public.units where name='ULM');
update public.month_codes set unit_id=(select id from public.units where name='ULM');
update public.entries set unit_id=(select id from public.units where name='ULM');
update public.submissions set unit_id=(select id from public.units where name='ULM');

alter table public.profiles alter column unit_id set not null;
alter table public.months alter column unit_id set not null;
alter table public.month_codes alter column unit_id set not null;
alter table public.entries alter column unit_id set not null;
alter table public.submissions alter column unit_id set not null;

alter table public.profiles add constraint profiles_unit_fk foreign key (unit_id) references public.units(id);
alter table public.profiles add constraint profiles_id_unit_unique unique (id,unit_id);

-- Libérer l'ancienne clé globale des mois et les anciennes références à celle-ci.
-- Les références sont reconstruites ci-dessous avec (unit_id,month_key).
do $$
declare c record;
begin
  for c in
    select conrelid::regclass as rel, conname
    from pg_constraint
    where contype='f' and confrelid in ('public.months'::regclass,'public.month_codes'::regclass)
  loop execute format('alter table %s drop constraint %I',c.rel,c.conname); end loop;
  for c in
    select conrelid::regclass as rel, conname
    from pg_constraint
    where contype in ('p','u') and conrelid='public.months'::regclass
  loop execute format('alter table %s drop constraint %I',c.rel,c.conname); end loop;
  for c in
    select conrelid::regclass as rel, conname
    from pg_constraint
    where contype='u' and conrelid='public.month_codes'::regclass
      and pg_get_constraintdef(oid) like '%month_key%'
  loop execute format('alter table %s drop constraint %I',c.rel,c.conname); end loop;
end $$;

alter table public.months add constraint months_pkey primary key (unit_id,month_key);
alter table public.month_codes add constraint month_codes_unit_month_fk
  foreign key (unit_id,month_key) references public.months(unit_id,month_key)
  on update cascade on delete cascade;
alter table public.month_codes add constraint month_codes_unit_month_id_unique unique (unit_id,month_key,id);
alter table public.month_codes add constraint month_codes_unit_month_code_unique unique (unit_id,month_key,code);
alter table public.entries add constraint entries_unit_month_fk
  foreign key (unit_id,month_key) references public.months(unit_id,month_key)
  on update cascade on delete cascade;
alter table public.entries add constraint entries_unit_code_fk
  foreign key (unit_id,month_key,code_id) references public.month_codes(unit_id,month_key,id)
  on update cascade on delete cascade;
alter table public.entries add constraint entries_user_unit_fk
  foreign key (user_id,unit_id) references public.profiles(id,unit_id);
alter table public.submissions add constraint submissions_unit_month_fk
  foreign key (unit_id,month_key) references public.months(unit_id,month_key)
  on update cascade on delete cascade;
alter table public.submissions add constraint submissions_user_unit_fk
  foreign key (user_id,unit_id) references public.profiles(id,unit_id);

create or replace function public.pointage_assign_signup_unit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare requested uuid;
begin
  if new.unit_id is null then
    begin
      requested := (select (raw_user_meta_data->>'unit_id')::uuid from auth.users where id=new.id);
    exception when invalid_text_representation then requested := null;
    end;
    if requested is not null and exists(select 1 from public.units where id=requested and active) then
      new.unit_id := requested;
    else
      -- Compatibilité avec les inscriptions déjà lancées avant la migration.
      new.unit_id := (select id from public.units where name='ULM');
    end if;
  end if;
  return new;
end $$;
create trigger pointage_assign_signup_unit before insert on public.profiles
for each row execute function public.pointage_assign_signup_unit();

create or replace function public.pointage_is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select is_admin from public.profiles where id=auth.uid()),false)
$$;
create or replace function public.pointage_user_unit()
returns uuid language sql stable security definer set search_path = '' as $$
  select unit_id from public.profiles where id=auth.uid() and active
$$;
revoke all on function public.pointage_is_admin() from public,anon;
revoke all on function public.pointage_user_unit() from public,anon;
grant execute on function public.pointage_is_admin() to authenticated;
grant execute on function public.pointage_user_unit() to authenticated;

-- Remplacer toutes les anciennes politiques sur ces tables afin qu'aucune
-- règle globale antérieure ne laisse lire ou modifier une autre unité.
do $$
declare p record;
begin
  for p in select schemaname,tablename,policyname from pg_policies
    where schemaname='public' and tablename=any(array['units','profiles','months','month_codes','entries','submissions'])
  loop execute format('drop policy %I on %I.%I',p.policyname,p.schemaname,p.tablename); end loop;
end $$;
alter table public.units enable row level security;
alter table public.profiles enable row level security;
alter table public.months enable row level security;
alter table public.month_codes enable row level security;
alter table public.entries enable row level security;
alter table public.submissions enable row level security;

grant select on public.units to anon,authenticated;
grant insert,update,delete on public.units to authenticated;
grant select,update on public.profiles to authenticated;
grant select,insert,update,delete on public.months,public.month_codes,public.entries,public.submissions to authenticated;

create policy units_public_list on public.units for select to anon,authenticated
using (active or (select public.pointage_is_admin()));
create policy units_admin_insert on public.units for insert to authenticated
with check ((select public.pointage_is_admin()));
create policy units_admin_update on public.units for update to authenticated
using ((select public.pointage_is_admin())) with check ((select public.pointage_is_admin()));

create policy profiles_read on public.profiles for select to authenticated
using (id=auth.uid() or (select public.pointage_is_admin()));
create policy profiles_admin_update on public.profiles for update to authenticated
using ((select public.pointage_is_admin())) with check ((select public.pointage_is_admin()));

create policy months_read on public.months for select to authenticated
using (unit_id=(select public.pointage_user_unit()) or (select public.pointage_is_admin()));
create policy months_admin_insert on public.months for insert to authenticated
with check ((select public.pointage_is_admin()));
create policy months_admin_update on public.months for update to authenticated
using ((select public.pointage_is_admin())) with check ((select public.pointage_is_admin()));
create policy months_admin_delete on public.months for delete to authenticated
using ((select public.pointage_is_admin()));

create policy codes_read on public.month_codes for select to authenticated
using (unit_id=(select public.pointage_user_unit()) or (select public.pointage_is_admin()));
create policy codes_admin_insert on public.month_codes for insert to authenticated
with check ((select public.pointage_is_admin()));
create policy codes_admin_update on public.month_codes for update to authenticated
using ((select public.pointage_is_admin())) with check ((select public.pointage_is_admin()));
create policy codes_admin_delete on public.month_codes for delete to authenticated
using ((select public.pointage_is_admin()));

create policy entries_read on public.entries for select to authenticated
using ((user_id=auth.uid() and unit_id=(select public.pointage_user_unit())) or (select public.pointage_is_admin()));
create policy entries_own_insert on public.entries for insert to authenticated
with check (user_id=auth.uid() and unit_id=(select public.pointage_user_unit())
  and exists(select 1 from public.months m where m.unit_id=entries.unit_id and m.month_key=entries.month_key and m.is_open)
  and not exists(select 1 from public.submissions s where s.user_id=auth.uid() and s.unit_id=entries.unit_id and s.month_key=entries.month_key));
create policy entries_own_update on public.entries for update to authenticated
using (user_id=auth.uid() and unit_id=(select public.pointage_user_unit())
  and exists(select 1 from public.months m where m.unit_id=entries.unit_id and m.month_key=entries.month_key and m.is_open)
  and not exists(select 1 from public.submissions s where s.user_id=auth.uid() and s.unit_id=entries.unit_id and s.month_key=entries.month_key))
with check (user_id=auth.uid() and unit_id=(select public.pointage_user_unit())
  and exists(select 1 from public.months m where m.unit_id=entries.unit_id and m.month_key=entries.month_key and m.is_open)
  and not exists(select 1 from public.submissions s where s.user_id=auth.uid() and s.unit_id=entries.unit_id and s.month_key=entries.month_key));
create policy entries_own_delete on public.entries for delete to authenticated
using (user_id=auth.uid() and unit_id=(select public.pointage_user_unit())
  and exists(select 1 from public.months m where m.unit_id=entries.unit_id and m.month_key=entries.month_key and m.is_open)
  and not exists(select 1 from public.submissions s where s.user_id=auth.uid() and s.unit_id=entries.unit_id and s.month_key=entries.month_key));

create policy submissions_read on public.submissions for select to authenticated
using ((user_id=auth.uid() and unit_id=(select public.pointage_user_unit())) or (select public.pointage_is_admin()));
create policy submissions_own_insert on public.submissions for insert to authenticated
with check (user_id=auth.uid() and unit_id=(select public.pointage_user_unit())
  and exists(select 1 from public.months m where m.unit_id=submissions.unit_id and m.month_key=submissions.month_key and m.is_open));
create policy submissions_own_delete on public.submissions for delete to authenticated
using (user_id=auth.uid() and unit_id=(select public.pointage_user_unit())
  and exists(select 1 from public.months m where m.unit_id=submissions.unit_id and m.month_key=submissions.month_key and m.is_open));

commit;
