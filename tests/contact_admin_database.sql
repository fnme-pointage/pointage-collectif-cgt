begin;
select set_config('test.user',(select id::text from public.profiles where active and not is_admin limit 1),true);
set local role service_role;
do $$begin
 if not public.pointage_claim_contact_send(current_setting('test.user')::uuid) then raise exception 'First send denied';end if;
 if not public.pointage_claim_contact_send(current_setting('test.user')::uuid) then raise exception 'Second send denied';end if;
 if not public.pointage_claim_contact_send(current_setting('test.user')::uuid) then raise exception 'Third send denied';end if;
 if public.pointage_claim_contact_send(current_setting('test.user')::uuid) then raise exception 'Rate limit failed';end if;
end;$$;
reset role;
set local role authenticated;
do $$begin
 begin
  perform public.pointage_claim_contact_send(current_setting('test.user')::uuid);
  raise exception 'Member can bypass verified endpoint';
 exception when insufficient_privilege then null;end;
 begin
  perform 1 from pointage_private.contact_send_attempts;
  raise exception 'Private attempts exposed';
 exception when insufficient_privilege then null;end;
end;$$;
reset role;
rollback;
select 'PASS: first three sends allowed, fourth denied, limiter and attempts inaccessible to members; rolled back' result;
