begin;
create temporary table template_test_entries as table public.entries;
create temporary table template_test_versions as table public.pointage_code_versions;
select set_config('test.admin',(select id::text from public.profiles where is_admin and active limit 1),true);
select set_config('test.user',(select id::text from public.profiles where not is_admin and active limit 1),true);
select set_config('request.jwt.claim.sub',current_setting('test.admin'),true);
set local role authenticated;
do $$declare snapshot jsonb;changed jsonb;before_id uuid;after_id uuid;before_codes jsonb;rev bigint;begin
 snapshot:=public.pointage_get_code_template();
 if jsonb_array_length(snapshot->'codes')<>26 then raise exception 'Expected 26 original codes';end if;
 insert into public.units(name) values('TEST modèle avant '||gen_random_uuid()) returning id into before_id;
 select jsonb_agg(jsonb_build_array(code,label,document,active) order by code) into before_codes from public.pointage_code_versions where unit_id=before_id;
 changed:=snapshot->'codes';
 changed:=jsonb_set(changed,'{0,label}',to_jsonb('Libellé type modifié'::text));
 changed:=jsonb_set(changed,'{0,active}','false');
 changed:=changed||jsonb_build_array(jsonb_build_object('code','TESTTYPE','label','Code type ajouté','document','Référence test','active',true));
 rev:=(snapshot->>'revision')::bigint;
 perform public.pointage_save_code_template(rev,changed);
 if (select jsonb_agg(jsonb_build_array(code,label,document,active) order by code) from public.pointage_code_versions where unit_id=before_id) is distinct from before_codes then raise exception 'Existing unit changed with template';end if;
 insert into public.units(name) values('TEST modèle après '||gen_random_uuid()) returning id into after_id;
 if (select count(*) from public.pointage_code_versions where unit_id=after_id)<>27 then raise exception 'New unit did not receive updated template';end if;
 if not exists(select 1 from public.pointage_code_versions where unit_id=after_id and code='TESTTYPE' and document='Référence test') then raise exception 'New code missing';end if;
 if not exists(select 1 from public.pointage_code_versions where unit_id=after_id and label='Libellé type modifié' and not active) then raise exception 'Inactive or edited template not copied';end if;
 perform public.pointage_ensure_year(after_id,2098);
 if not exists(select 1 from public.month_codes where unit_id=after_id and month_key='2098-01' and code='TESTTYPE') then raise exception 'Copied catalogue not used for user months';end if;
 perform public.pointage_save_catalogue(array[after_id],'2098-01',jsonb_build_array(jsonb_build_object('catalogue_id',(select catalogue_id from public.pointage_code_versions where unit_id=after_id and code='TESTTYPE'),'code','TESTTYPE','label','Personnalisation locale','document','Document local','active',true)));
 if (public.pointage_get_code_template()->'codes')::text like '%Personnalisation locale%' then raise exception 'Local change modified template';end if;
 begin
  perform public.pointage_save_code_template(rev,changed);
  raise exception 'Stale revision accepted';
 exception when raise_exception then if sqlerrm='Stale revision accepted' then raise;end if;end;
 begin
  perform public.pointage_save_code_template(rev+1,jsonb_build_array(jsonb_build_object('code','X','label','One'),jsonb_build_object('code','X','label','Two')));
  raise exception 'Duplicate accepted';
 exception when raise_exception then if sqlerrm='Duplicate accepted' then raise;end if;end;
end;$$;
select set_config('request.jwt.claim.sub',current_setting('test.user'),true);
do $$begin
 if exists(select 1 from public.pointage_code_template) then raise exception 'Ordinary user sees template';end if;
 begin perform public.pointage_get_code_template();raise exception 'Ordinary user read accepted';exception when insufficient_privilege then null;end;
 begin perform public.pointage_save_code_template(1,'[]');raise exception 'Ordinary user write accepted';exception when insufficient_privilege then null;end;
end;$$;
reset role;
do $$begin
 if exists((select * from template_test_entries except select * from public.entries) union all (select * from public.entries except select * from template_test_entries)) then raise exception 'Existing pointages changed';end if;
 if exists(select * from template_test_versions except select * from public.pointage_code_versions) then raise exception 'Existing catalogues changed';end if;
end;$$;
rollback;
