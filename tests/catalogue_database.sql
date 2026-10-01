-- Runs against the connected test database inside a transaction; no test data is committed.
begin;
select set_config('test.admin',(select id::text from public.profiles where is_admin limit 1),true);
select set_config('test.user',(select id::text from public.profiles where active and not is_admin limit 1),true);
select set_config('test.unit',(select unit_id::text from public.profiles where id=current_setting('test.user')::uuid),true);
select set_config('test.other',(select id::text from public.units where name<>'ADMIN' and active and id<>current_setting('test.unit')::uuid limit 1),true);
select set_config('test.catalogue',(select catalogue_id::text from public.pointage_code_versions where unit_id=current_setting('test.unit')::uuid and code='D4' limit 1),true);
select set_config('request.jwt.claim.sub',current_setting('test.admin'),true);
set local role authenticated;
select public.pointage_ensure_year(current_setting('test.unit')::uuid,2098);
select public.pointage_save_catalogue(array[current_setting('test.unit')::uuid,current_setting('test.other')::uuid],'2098-01',jsonb_build_array(jsonb_build_object('catalogue_id',current_setting('test.catalogue'),'code','D4','label','Test label A','document','Test reference A','active',true)));
select set_config('request.jwt.claim.sub',current_setting('test.user'),true);
do $$begin
 if (select count(*) from public.months where unit_id=current_setting('test.unit')::uuid and month_key like '2098-%')<>12 then raise exception 'Expected 12 months';end if;
 if exists(select 1 from public.months where unit_id=current_setting('test.other')::uuid) then raise exception 'Cross-unit read leaked';end if;
 begin
  perform public.pointage_ensure_year(current_setting('test.other')::uuid,2098);
  raise exception 'Cross-unit creation should fail';
 exception when insufficient_privilege then null;end;
 begin
  perform public.pointage_save_catalogue(array[current_setting('test.unit')::uuid],'2098-01','[]');
  raise exception 'Member catalogue write should fail';
 exception when insufficient_privilege then null;end;
end;$$;
select public.pointage_save_entries(current_setting('test.unit')::uuid,'2098-01',jsonb_build_array(jsonb_build_object('code_id',(select id from public.month_codes where unit_id=current_setting('test.unit')::uuid and month_key='2098-01' and code='D4'),'hours',7.5)));
select set_config('request.jwt.claim.sub',current_setting('test.admin'),true);
select public.pointage_save_catalogue(array[current_setting('test.unit')::uuid,current_setting('test.other')::uuid],'2098-01',jsonb_build_array(jsonb_build_object('catalogue_id',current_setting('test.catalogue'),'code','TESTD4','label','Test label B','document','Test reference B','active',true)));
select public.pointage_ensure_year(current_setting('test.other')::uuid,2098);
do $$begin
 if not exists(select 1 from public.month_codes where unit_id=current_setting('test.other')::uuid and month_key='2098-01' and code='TESTD4') then raise exception 'Future / multi-unit propagation failed';end if;
 begin
  perform public.pointage_save_catalogue(array[current_setting('test.unit')::uuid],'2098-01',jsonb_build_array(jsonb_build_object('catalogue_id',current_setting('test.catalogue'),'code','S4','label','Duplicate','active',true)));
  raise exception 'Duplicate should fail';
 exception when raise_exception then if sqlerrm='Duplicate should fail' then raise;end if;end;
end;$$;
select set_config('request.jwt.claim.sub',current_setting('test.user'),true);
select public.pointage_save_entries(current_setting('test.unit')::uuid,'2098-01',jsonb_build_array(jsonb_build_object('code_id',(select id from public.month_codes where unit_id=current_setting('test.unit')::uuid and month_key='2098-01' and code='TESTD4'),'hours',8.25)));
do $$begin
 if not exists(select 1 from public.entries where month_key='2098-01' and hours=8.25 and saved_code='D4' and saved_label='Test label A' and saved_document='Test reference A') then raise exception 'Historical snapshot or update failed';end if;
end;$$;
select set_config('request.jwt.claim.sub',current_setting('test.admin'),true);
update public.months set is_open=false where unit_id=current_setting('test.unit')::uuid and month_key='2098-01';
select public.pointage_save_catalogue(array[current_setting('test.unit')::uuid],'2098-01',jsonb_build_array(jsonb_build_object('catalogue_id',current_setting('test.catalogue'),'code','TESTD4','label','Disabled label','document','Disabled reference','active',false)));
do $$begin
 if not exists(select 1 from public.month_codes where unit_id=current_setting('test.unit')::uuid and month_key='2098-01' and label='Test label B' and active) then raise exception 'Closed month modified';end if;
 if exists(select 1 from public.month_codes where unit_id=current_setting('test.unit')::uuid and month_key='2098-02' and code='TESTD4' and active) then raise exception 'Deactivation did not propagate';end if;
end;$$;
select set_config('request.jwt.claim.sub',current_setting('test.user'),true);
do $$begin
 begin
  perform public.pointage_save_entries(current_setting('test.unit')::uuid,'2098-02',jsonb_build_array(jsonb_build_object('code_id',(select id from public.month_codes where unit_id=current_setting('test.unit')::uuid and month_key='2098-02' and code='TESTD4'),'hours',1)));
  raise exception 'Disabled new code should fail';
 exception when raise_exception then if sqlerrm='Disabled new code should fail' then raise;end if;end;
end;$$;
reset role;
select set_config('request.jwt.claim.sub','',true);
set local role anon;
do $$begin
 begin
  perform public.pointage_ensure_year(current_setting('test.unit')::uuid,2098);
  raise exception 'Anonymous should fail';
 exception when insufficient_privilege then null;end;
end;$$;
reset role;
rollback;
select 'PASS: 12 months, unit isolation, admin-only catalogue, future propagation, duplicate rejection, saved historical metadata, closed month preservation, deactivation, anonymous denial; transaction rolled back' as result;
