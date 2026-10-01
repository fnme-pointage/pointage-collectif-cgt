begin;
select set_config('test.user',(select id::text from public.profiles where active and not is_admin limit 1),true);
select set_config('test.unit',(select unit_id::text from public.profiles where id=current_setting('test.user')::uuid),true);
select set_config('request.jwt.claim.sub',current_setting('test.user'),true);
do $$begin
 if exists(select 1 from pointage_private.entries_before_time_formats_20261001 b left join public.entries e on e.id=b.id where e.id is null or e.hours<>b.hours or e.duration_seconds<>round(b.hours*3600) or e.saved_code is distinct from b.saved_code or e.saved_document is distinct from b.saved_document) then raise exception 'Existing entries changed during precision migration';end if;
end;$$;
set local role authenticated;
select public.pointage_ensure_year(current_setting('test.unit')::uuid,2096);
select set_config('test.code',(select id::text from public.month_codes where unit_id=current_setting('test.unit')::uuid and month_key='2096-01' and active limit 1),true);
select public.pointage_save_entries(current_setting('test.unit')::uuid,'2096-01',jsonb_build_array(jsonb_build_object('code_id',current_setting('test.code')::bigint,'hours',0.016667,'duration_seconds',60)));
do $$begin
 if not exists(select 1 from public.entries where user_id=auth.uid() and month_key='2096-01' and duration_seconds=60 and hours=0.02) then raise exception 'Exact minute not saved';end if;
end;$$;
-- An unchanged rounded-hours submission from an old client keeps exact precision.
select public.pointage_save_entries(current_setting('test.unit')::uuid,'2096-01',jsonb_build_array(jsonb_build_object('code_id',current_setting('test.code')::bigint,'hours',0.02)));
do $$begin
 if (select duration_seconds from public.entries where user_id=auth.uid() and month_key='2096-01')<>60 then raise exception 'Legacy unchanged save lost precision';end if;
end;$$;
-- Decimal submissions remain supported.
select public.pointage_save_entries(current_setting('test.unit')::uuid,'2096-01',jsonb_build_array(jsonb_build_object('code_id',current_setting('test.code')::bigint,'hours',1.50)));
do $$begin
 if (select duration_seconds from public.entries where user_id=auth.uid() and month_key='2096-01')<>5400 then raise exception 'Legacy decimal duration incorrect';end if;
 begin
  perform public.pointage_save_entries(current_setting('test.unit')::uuid,'2096-01',jsonb_build_array(jsonb_build_object('code_id',current_setting('test.code')::bigint,'hours',1.50,'duration_seconds',60)));
  raise exception 'Mismatch should have been rejected';
 exception when raise_exception then if sqlerrm='Mismatch should have been rejected' then raise;end if;end;
end;$$;
-- Repeated one-minute durations across five years have no accumulated rounding.
do $$declare yr integer; mo integer; code_id bigint; sec_total bigint;begin
 for yr in 2096..2100 loop
  perform public.pointage_ensure_year(current_setting('test.unit')::uuid,yr);
  for mo in 1..12 loop
   select id into code_id from public.month_codes where unit_id=current_setting('test.unit')::uuid and month_key=yr||'-'||lpad(mo::text,2,'0') and active limit 1;
   perform public.pointage_save_entries(current_setting('test.unit')::uuid,yr||'-'||lpad(mo::text,2,'0'),jsonb_build_array(jsonb_build_object('code_id',code_id,'hours',0.016667,'duration_seconds',60)));
  end loop;
 end loop;
 select sum(duration_seconds) into sec_total from public.entries where user_id=auth.uid() and month_key between '2096-01' and '2100-12';
 if sec_total<>3600 then raise exception 'Expected 3600 seconds, got %',sec_total;end if;
end;$$;
reset role;
rollback;
select 'PASS: prior entries preserved, exact one-minute save, legacy unchanged/edited decimal clients, mismatches rejected, 60 one-minute entries total 3600 seconds; fixtures rolled back' result;
