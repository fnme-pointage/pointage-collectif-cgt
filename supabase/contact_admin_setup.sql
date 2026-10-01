-- Only send-attempt metadata is stored, never message content.
create table if not exists pointage_private.contact_send_attempts (
 id bigint generated always as identity primary key,
 user_id uuid not null references public.profiles(id) on delete cascade,
 created_at timestamptz not null default now()
);
alter table pointage_private.contact_send_attempts enable row level security;
revoke all on pointage_private.contact_send_attempts from public,anon,authenticated;
grant select,insert,delete on pointage_private.contact_send_attempts to service_role;
grant usage,select on sequence pointage_private.contact_send_attempts_id_seq to service_role;
create index if not exists contact_send_attempts_user_time on pointage_private.contact_send_attempts(user_id,created_at);
create or replace function public.pointage_claim_contact_send(p_user uuid) returns boolean
language plpgsql security invoker set search_path='' as $$
begin
 if not exists(select 1 from public.profiles where id=p_user and active and not is_admin) then return false;end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('pointage-contact:'||p_user::text,0));
 delete from pointage_private.contact_send_attempts where created_at<now()-interval '7 days';
 if (select count(*) from pointage_private.contact_send_attempts where user_id=p_user and created_at>now()-interval '1 hour')>=3 then return false;end if;
 insert into pointage_private.contact_send_attempts(user_id) values(p_user);
 return true;
end;$$;
revoke all on function public.pointage_claim_contact_send(uuid) from public,anon,authenticated;
grant execute on function public.pointage_claim_contact_send(uuid) to service_role;
