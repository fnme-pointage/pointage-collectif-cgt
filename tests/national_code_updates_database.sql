begin;
create temporary table national_test_entries as table public.entries;
create temporary table national_test_versions as table public.pointage_code_versions;
select set_config('test.admin',(select id::text from public.profiles where is_admin and active limit 1),true);
select set_config('test.user',(select id::text from public.profiles where not is_admin and active limit 1),true);
select set_config('request.jwt.claim.sub',current_setting('test.admin'),true);
do $$declare snap jsonb;changed jsonb;result jsonb;u1 uuid;u2 uuid;u3 uuid;local_id uuid;baseline_id uuid;revision_before bigint;versions_before bigint;expected_units integer;begin
 insert into public.units(name) values('TEST national A '||gen_random_uuid()) returning id into u1;
 insert into public.units(name) values('TEST national B '||gen_random_uuid()) returning id into u2;
 perform public.pointage_ensure_year(u1,2099);perform public.pointage_ensure_year(u2,2099);
 update public.months set is_open=false where unit_id=u2 and month_key='2099-02';
 select catalogue_id into baseline_id from public.pointage_code_versions where unit_id=u1 and code='D4' limit 1;
 perform public.pointage_save_catalogue(array[u1],'2099-01',jsonb_build_array(jsonb_build_object('catalogue_id',baseline_id,'code','D4','label','DS LOCAL PERSONNALISÉ','document','DOCUMENT LOCAL','active',true),jsonb_build_object('code','CLOCAL','label','Code local privé à unité','document','Doc local','active',true)));
 snap:=public.pointage_get_code_template();changed:=snap->'codes'||jsonb_build_array(jsonb_build_object('code','NTESTA','label','Nouveau code national','document','Accord national','active',true));
 select count(*) into expected_units from public.units where active and name<>'ADMIN';
 result:=public.pointage_save_national_codes((snap->>'revision')::bigint,changed,true,'2099-01');
 if (result->>'changed_codes')::integer<>1 or (result->>'applied_units')::integer<>expected_units then raise exception 'Incorrect national scope or changed-code count';end if;
 if exists(select 1 from public.units u where active and name<>'ADMIN' and not exists(select 1 from public.pointage_code_versions v where v.unit_id=u.id and v.code='NTESTA')) then raise exception 'An active unit missed the national code';end if;
 if not exists(select 1 from public.month_codes where unit_id=u1 and month_key='2099-01' and code='D4' and label='DS LOCAL PERSONNALISÉ' and document='DOCUMENT LOCAL') then raise exception 'Local customization lost';end if;
 if not exists(select 1 from public.month_codes where unit_id=u1 and month_key='2099-01' and code='CLOCAL') then raise exception 'Local code lost';end if;
 if not exists(select 1 from public.month_codes where unit_id=u2 and month_key='2099-01' and code='NTESTA') then raise exception 'Open month not updated';end if;
 if exists(select 1 from public.month_codes where unit_id=u2 and month_key='2099-02' and code='NTESTA') then raise exception 'Closed month changed';end if;
 insert into public.units(name) values('TEST national futur '||gen_random_uuid()) returning id into u3;
 if not exists(select 1 from public.pointage_code_versions where unit_id=u3 and code='NTESTA') then raise exception 'Future unit missed updated template';end if;
 snap:=public.pointage_get_code_template();revision_before:=(snap->>'revision')::bigint;select count(*) into versions_before from public.pointage_code_versions;
 changed:=snap->'codes'||jsonb_build_array(jsonb_build_object('code','CLOCAL','label','National conflict','active',true));
 begin
  perform public.pointage_save_national_codes(revision_before,changed,true,'2099-01');raise exception 'Conflict accepted';
 exception when raise_exception then if sqlerrm='Conflict accepted' then raise;end if;end;
 if (public.pointage_get_code_template()->>'revision')::bigint<>revision_before or (select count(*) from public.pointage_code_versions)<>versions_before then raise exception 'Failed national update was not atomic';end if;
 changed:=snap->'codes'||jsonb_build_array(jsonb_build_object('code','FUTURTEST','label','Only future units','active',true));
 result:=public.pointage_save_national_codes(revision_before,changed,false,null);
 if exists(select 1 from public.pointage_code_versions where code='FUTURTEST') then raise exception 'Template-only edit touched existing units';end if;
end;$$;
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.user'),true);
do $$begin
 begin perform public.pointage_save_national_codes(1,'[]',true,'2099-01');raise exception 'Ordinary user accepted';exception when insufficient_privilege then null;end;
end;$$;
reset role;
do $$begin
 if exists((select * from national_test_entries except select * from public.entries) union all (select * from public.entries except select * from national_test_entries)) then raise exception 'Saved entries modified';end if;
 if exists(select * from national_test_versions except select * from public.pointage_code_versions) then raise exception 'Original catalogue versions modified';end if;
end;$$;
rollback;
