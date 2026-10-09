-- Notification de nouvelle inscription aux responsables de division et activation limitee a leur perimetre.
CREATE OR REPLACE FUNCTION public.pointage_signup_division_recipients(p_user_id uuid)
RETURNS TABLE(email text)
LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
 SELECT DISTINCT lower(btrim(manager.email))
 FROM public.profiles applicant
 JOIN public.units requested ON requested.id=applicant.requested_unit_id AND requested.active
 JOIN public.pointage_divisions division ON division.id=requested.division_id AND division.active
 JOIN public.profiles manager ON manager.managed_division_id=division.id
 WHERE applicant.id=p_user_id AND NOT applicant.active AND NOT applicant.is_admin
   AND manager.active AND manager.is_division_manager AND NOT manager.is_admin
   AND manager.email IS NOT NULL AND btrim(manager.email)<>''
   AND EXISTS (SELECT 1 FROM auth.users confirmed WHERE confirmed.id=applicant.id AND confirmed.email_confirmed_at IS NOT NULL);
$$;
REVOKE ALL ON FUNCTION public.pointage_signup_division_recipients(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pointage_signup_division_recipients(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.pointage_division_pending_signups()
RETURNS SETOF public.profiles
LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
 SELECT applicant.*
 FROM public.profiles caller
 JOIN public.pointage_divisions division ON division.id=caller.managed_division_id AND division.active
 JOIN public.units requested ON requested.division_id=division.id AND requested.active
 JOIN public.profiles applicant ON applicant.requested_unit_id=requested.id
 JOIN auth.users confirmed ON confirmed.id=applicant.id AND confirmed.email_confirmed_at IS NOT NULL
 WHERE caller.id=auth.uid() AND caller.active AND caller.is_division_manager AND NOT caller.is_admin
   AND NOT applicant.active AND NOT applicant.is_admin
   AND applicant.unit_id IS DISTINCT FROM requested.id;
$$;
REVOKE ALL ON FUNCTION public.pointage_division_pending_signups() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_division_pending_signups() TO authenticated;

CREATE OR REPLACE FUNCTION public.pointage_division_approve_signup(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE target public.profiles%ROWTYPE;
BEGIN
 SELECT applicant.* INTO target FROM public.profiles applicant
 JOIN public.units requested ON requested.id=applicant.requested_unit_id AND requested.active
 JOIN public.pointage_divisions division ON division.id=requested.division_id AND division.active
 JOIN public.profiles caller ON caller.managed_division_id=division.id
 WHERE applicant.id=p_user_id AND NOT applicant.active AND NOT applicant.is_admin
   AND caller.id=auth.uid() AND caller.active AND caller.is_division_manager AND NOT caller.is_admin
   AND EXISTS(SELECT 1 FROM auth.users confirmed WHERE confirmed.id=applicant.id AND confirmed.email_confirmed_at IS NOT NULL)
 FOR UPDATE OF applicant;
 IF NOT FOUND THEN RAISE EXCEPTION 'Inscription non autorisee ou non confirmee' USING ERRCODE='42501'; END IF;
 UPDATE public.profiles SET unit_id=target.requested_unit_id,active=true WHERE id=target.id AND NOT active AND NOT is_admin;
END;
$$;
REVOKE ALL ON FUNCTION public.pointage_division_approve_signup(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_division_approve_signup(uuid) TO authenticated;