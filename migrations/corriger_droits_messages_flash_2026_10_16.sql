-- Correct the authenticated RPC path for national/unit flash publication.
-- The called security-definer function continues to verify admin or manager scope.
grant execute on function pointage_private.create_unit_flash_message(uuid,text,text,timestamptz,timestamptz,boolean,uuid) to authenticated;
revoke execute on function public.pointage_create_flash_message(uuid,text,text,timestamptz,timestamptz,boolean,uuid) from anon;
