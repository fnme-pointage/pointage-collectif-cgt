-- Transactional fixtures; neither PDF contents nor user data are committed.
begin;
select set_config('test.admin',(select id::text from public.profiles where is_admin limit 1),true);
select set_config('test.user',(select id::text from public.profiles where active and not is_admin limit 1),true);
select set_config('test.unit',(select unit_id::text from public.profiles where id=current_setting('test.user')::uuid),true);
select set_config('test.other',(select id::text from public.units where name<>'ADMIN' and id<>current_setting('test.unit')::uuid limit 1),true);
select set_config('test.national',gen_random_uuid()::text,true);
select set_config('test.local',gen_random_uuid()::text,true);
select set_config('test.foreign',gen_random_uuid()::text,true);
select set_config('request.jwt.claim.sub',current_setting('test.admin'),true);
set local role authenticated;
insert into public.pointage_documents(id,title,file_path,file_size,unit_id) values
(current_setting('test.national')::uuid,'Test national',current_setting('test.national')||'.pdf',1,null),
(current_setting('test.local')::uuid,'Test local',current_setting('test.local')||'.pdf',1,current_setting('test.unit')::uuid),
(current_setting('test.foreign')::uuid,'Test other',current_setting('test.foreign')||'.pdf',1,current_setting('test.other')::uuid);
insert into storage.objects(bucket_id,name) values
('pointage-documents',current_setting('test.national')||'.pdf'),
('pointage-documents',current_setting('test.local')||'.pdf'),
('pointage-documents',current_setting('test.foreign')||'.pdf');
select set_config('request.jwt.claim.sub',current_setting('test.user'),true);
do $$declare n integer;begin
 select count(*) into n from public.pointage_documents where id in (current_setting('test.national')::uuid,current_setting('test.local')::uuid,current_setting('test.foreign')::uuid);
 if n<>2 then raise exception 'Expected national + own unit only, got %',n;end if;
 if exists(select 1 from public.pointage_documents where id=current_setting('test.foreign')::uuid) then raise exception 'Foreign metadata exposed';end if;
 select count(*) into n from storage.objects where bucket_id='pointage-documents' and name in (current_setting('test.national')||'.pdf',current_setting('test.local')||'.pdf',current_setting('test.foreign')||'.pdf');
 if n<>2 then raise exception 'Storage isolation failed: %',n;end if;
 begin
  insert into public.pointage_documents(title,file_path,file_size) values('Denied',gen_random_uuid()::text||'.pdf',1);
  raise exception 'Member should not upload';
 exception when insufficient_privilege then null;end;
 delete from public.pointage_documents where id=current_setting('test.local')::uuid;
 get diagnostics n=row_count;if n<>0 then raise exception 'Member should not delete';end if;
end;$$;
reset role;
update public.profiles set active=false where id=current_setting('test.user')::uuid;
set local role authenticated;
do $$begin
 if exists(select 1 from public.pointage_documents) then raise exception 'Inactive user can read metadata';end if;
 if exists(select 1 from storage.objects where bucket_id='pointage-documents') then raise exception 'Inactive user can read files';end if;
end;$$;
select set_config('request.jwt.claim.sub',current_setting('test.admin'),true);
do $$declare n integer;begin
 select count(*) into n from public.pointage_documents where id in (current_setting('test.national')::uuid,current_setting('test.local')::uuid,current_setting('test.foreign')::uuid);
 if n<>3 then raise exception 'Admin cannot access all bases';end if;
 select count(*) into n from storage.objects where bucket_id='pointage-documents' and name in (current_setting('test.national')||'.pdf',current_setting('test.local')||'.pdf',current_setting('test.foreign')||'.pdf');
 if n<>3 then raise exception 'Admin cannot access all files';end if;
end;$$;
reset role;
rollback;
select 'PASS: national and own unit access, foreign unit denied for metadata and files, inactive user denied, admin access, member writes denied; fixtures rolled back' result;
