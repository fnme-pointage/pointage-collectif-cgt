-- Liste type indépendante. Les unités existantes et leurs pointages ne sont pas modifiés.
create table public.pointage_code_template (
 catalogue_id uuid primary key references public.pointage_code_catalogue(id),
 code text not null check(length(code) between 1 and 30 and code=upper(btrim(code))),
 label text not null check(length(btrim(label)) between 1 and 300),
 document text not null default '' check(length(document)<=2000),
 active boolean not null default true,
 position integer not null check(position>=0),
 unique(code)
);
create table public.pointage_code_template_state (
 id boolean primary key default true check(id),
 revision bigint not null default 1
);
alter table public.pointage_code_template enable row level security;
alter table public.pointage_code_template_state enable row level security;
revoke all on public.pointage_code_template,public.pointage_code_template_state from public,anon,authenticated;
grant select on public.pointage_code_template,public.pointage_code_template_state to authenticated;
create policy code_template_admin_read on public.pointage_code_template for select to authenticated using ((select public.pointage_is_admin()));
create policy code_template_state_admin_read on public.pointage_code_template_state for select to authenticated using ((select public.pointage_is_admin()));
insert into public.pointage_code_template_state(id) values(true);
insert into public.pointage_code_template(catalogue_id,code,label,document,active,position)
select catalogue_id,code,label,document,active,row_number() over(order by id)-1
from (select distinct on(catalogue_id) * from public.pointage_code_versions where effective_month='1900-01' order by catalogue_id,id) original;
-- Private rollback reference for the original initialization function.
create table pointage_private.code_template_initial_backup as
select now() saved_at,pg_get_functiondef('pointage_internal.ensure_year(uuid,integer)'::regprocedure) ensure_year_definition,
 (select jsonb_agg(to_jsonb(t) order by position) from public.pointage_code_template t) initial_codes;
alter table pointage_private.code_template_initial_backup enable row level security;
revoke all on pointage_private.code_template_initial_backup from public,anon,authenticated;

create function pointage_internal.get_code_template() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.pointage_is_admin() then raise exception 'Action réservée à l’administrateur' using errcode='42501';end if;
 return (select jsonb_build_object('revision',revision,'codes',(select coalesce(jsonb_agg(to_jsonb(t) order by position),'[]'::jsonb) from public.pointage_code_template t)) from public.pointage_code_template_state where id);
end;$$;
create function public.pointage_get_code_template() returns jsonb language sql security invoker set search_path='' as $$select pointage_internal.get_code_template()$$;
revoke all on function pointage_internal.get_code_template(),public.pointage_get_code_template() from public,anon;
grant execute on function pointage_internal.get_code_template(),public.pointage_get_code_template() to authenticated;

create function pointage_internal.save_code_template(p_revision bigint,p_codes jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c jsonb;key uuid;keys uuid[]:='{}';pos integer:=0;revision_now bigint;
begin
 if auth.uid() is null or not public.pointage_is_admin() then raise exception 'Action réservée à l’administrateur' using errcode='42501';end if;
 if p_codes is null or jsonb_typeof(p_codes)<>'array' then raise exception 'Liste type invalide';end if;
 if jsonb_array_length(p_codes)=0 or jsonb_array_length(p_codes)>500 then raise exception 'La liste type doit contenir entre 1 et 500 codes';end if;
 if exists(select 1 from jsonb_array_elements(p_codes) v group by upper(btrim(v->>'code')) having count(*)>1) then raise exception 'Deux codes identiques sont présents';end if;
 perform pg_advisory_xact_lock(hashtextextended('pointage-code-template',0));
 select revision into revision_now from public.pointage_code_template_state where id for update;
 if p_revision is distinct from revision_now then raise exception 'La liste type a été modifiée ailleurs. Recharge-la avant de recommencer.';end if;
 for c in select value from jsonb_array_elements(p_codes) loop
  if nullif(btrim(c->>'code'),'') is null or nullif(btrim(c->>'label'),'') is null then raise exception 'Chaque code doit avoir un code et un libellé';end if;
  key:=nullif(c->>'catalogue_id','')::uuid;
  if key is null then insert into public.pointage_code_catalogue default values returning id into key;
  elsif not exists(select 1 from public.pointage_code_template where catalogue_id=key) then raise exception 'Code de référence inconnu';end if;
  if key=any(keys) then raise exception 'Code répété dans la liste';end if;
  keys:=array_append(keys,key);
  -- Validate before replacing the snapshot, keeping existing code identities.
  pos:=pos+1;
 end loop;
 delete from public.pointage_code_template;
 pos:=0;
 for c in select value from jsonb_array_elements(p_codes) loop
  pos:=pos+1;
  insert into public.pointage_code_template(catalogue_id,code,label,document,active,position)
  values(keys[pos],upper(btrim(c->>'code')),btrim(c->>'label'),coalesce(c->>'document',''),coalesce((c->>'active')::boolean,true),pos-1);
 end loop;
 update public.pointage_code_template_state set revision=revision+1 where id;
 return pointage_internal.get_code_template();
end;$$;
create function public.pointage_save_code_template(p_revision bigint,p_codes jsonb) returns jsonb language sql security invoker set search_path='' as $$select pointage_internal.save_code_template(p_revision,p_codes)$$;
revoke all on function pointage_internal.save_code_template(bigint,jsonb),public.pointage_save_code_template(bigint,jsonb) from public,anon;
grant execute on function pointage_internal.save_code_template(bigint,jsonb),public.pointage_save_code_template(bigint,jsonb) to authenticated;

create function pointage_internal.initialize_unit_template() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.name='ADMIN' then return new;end if;
 perform pg_advisory_xact_lock(hashtextextended('pointage-code-template',0));
 insert into public.pointage_code_versions(catalogue_id,unit_id,effective_month,code,label,document,active)
 select catalogue_id,new.id,'1900-01',code,label,document,active from public.pointage_code_template order by position;
 return new;
end;$$;
revoke all on function pointage_internal.initialize_unit_template() from public,anon,authenticated;
create trigger units_initialize_code_template after insert on public.units for each row execute function pointage_internal.initialize_unit_template();

create or replace function pointage_internal.ensure_year(p_unit uuid,p_year integer) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not (public.pointage_is_admin() or p_unit=public.pointage_user_unit()) then raise exception 'Accès refusé' using errcode='42501';end if;
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
end;$$;
