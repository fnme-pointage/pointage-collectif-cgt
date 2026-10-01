begin;
select set_config('test.admin',(select id::text from public.profiles where is_admin limit 1),true);
select set_config('test.user',(select user_id::text from public.entries limit 1),true);
select set_config('test.entry',(select id::text from public.entries where user_id=current_setting('test.user')::uuid limit 1),true);
select set_config('test.unit',(select unit_id::text from public.profiles where id=current_setting('test.user')::uuid),true);
select set_config('request.jwt.claim.sub',current_setting('test.admin'),true);
set local role authenticated;
select public.pointage_set_maintenance(true);
select set_config('request.jwt.claim.sub',current_setting('test.user'),true);
do $$
declare r public.entries; blocked boolean; touched integer;
begin
 select * into r from public.entries where id=current_setting('test.entry')::bigint;
 if not (select locked from public.pointage_maintenance where id=true) then raise exception 'Lock not visible to member';end if;
 begin
  perform public.pointage_save_entries(r.unit_id,r.month_key,'[]');
  raise exception 'Empty save should be blocked';
 exception when raise_exception then if sqlerrm not like 'Saisies bloquées pour maintenance%' then raise;end if;end;
 begin
  update public.entries set hours=hours+1 where id=r.id;
  raise exception 'Direct update should be blocked';
 exception when raise_exception then if sqlerrm not like 'Saisies bloquées pour maintenance%' then raise;end if;end;
 begin
  delete from public.entries where id=r.id;
  raise exception 'Direct delete should be blocked';
 exception when raise_exception then if sqlerrm not like 'Saisies bloquées pour maintenance%' then raise;end if;end;
 begin
  insert into public.entries(user_id,unit_id,month_key,code_id,hours) values(r.user_id,r.unit_id,r.month_key,r.code_id,1);
  raise exception 'Direct insert should be blocked';
 exception when raise_exception then if sqlerrm not like 'Saisies bloquées pour maintenance%' then raise;end if;end;
 begin
  perform public.pointage_set_maintenance(false);
  raise exception 'Member should not unlock';
 exception when insufficient_privilege then null;end;
 update public.pointage_maintenance set locked=false where id=true;
 get diagnostics touched=row_count;
 if touched<>0 then raise exception 'Member settings write should be denied';end if;
 if (select hours from public.entries where id=r.id) is distinct from r.hours then raise exception 'Saved data changed during maintenance';end if;
end;$$;
select set_config('request.jwt.claim.sub',current_setting('test.admin'),true);
-- Catalogue changes remain available while entries are blocked.
select public.pointage_save_catalogue(array[current_setting('test.unit')::uuid],'2099-01',
 jsonb_build_array(jsonb_build_object('catalogue_id',(select catalogue_id from public.pointage_code_versions where unit_id=current_setting('test.unit')::uuid and code='D4' limit 1),'code','D4','label','Maintenance catalogue test','document','Test','active',true)));
select public.pointage_set_maintenance(false);
select set_config('request.jwt.claim.sub',current_setting('test.user'),true);
do $$declare original numeric;begin
 select hours into original from public.entries where id=current_setting('test.entry')::bigint;
 update public.entries set hours=hours+1 where id=current_setting('test.entry')::bigint;
 if (select hours from public.entries where id=current_setting('test.entry')::bigint)<>original+1 then raise exception 'Update did not resume';end if;
end;$$;
reset role;
rollback;
select 'PASS: global lock, existing-client insert/update/delete and RPC denial, user cannot unlock, admin catalogue remains writable, saved data preserved, resume allowed; rolled back' as result;
