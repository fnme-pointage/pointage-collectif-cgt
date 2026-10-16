-- Affecter les nouveaux comptes a leur unite demandee, sans activation automatique.
-- Le rattachement ne donne aucun droit tant que profiles.active = false.
CREATE OR REPLACE FUNCTION public.pointage_assign_signup_unit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  IF NEW.requested_unit_id IS NULL THEN
    SELECT u.id INTO NEW.requested_unit_id
    FROM auth.users a JOIN public.units u
      ON u.id::text=lower(btrim(a.raw_user_meta_data->>'unit_id'))
    WHERE a.id=NEW.id AND u.active AND u.name<>'ADMIN';
  END IF;
  IF NEW.unit_id IS NULL THEN
    SELECT u.id INTO NEW.unit_id
    FROM public.units u WHERE u.id=NEW.requested_unit_id AND u.active AND u.name<>'ADMIN';
    IF NEW.unit_id IS NULL THEN
      RAISE EXCEPTION 'Selectionner une unite active pour creer le compte';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

-- Les responsables de division voient egalement les inscriptions de leur unite
-- deja rattachees, toujours non activees et avec adresse e-mail confirmee.
CREATE OR REPLACE FUNCTION public.pointage_division_pending_signups()
RETURNS SETOF public.profiles LANGUAGE sql SECURITY DEFINER SET search_path TO ''
AS $function$
 SELECT applicant.*
 FROM public.profiles caller
 JOIN public.pointage_divisions division ON division.id=caller.managed_division_id AND division.active
 JOIN public.units requested ON requested.division_id=division.id AND requested.active
 JOIN public.profiles applicant ON applicant.requested_unit_id=requested.id
 JOIN auth.users confirmed ON confirmed.id=applicant.id AND confirmed.email_confirmed_at IS NOT NULL
 WHERE caller.id=auth.uid() AND caller.active AND caller.is_division_manager AND NOT caller.is_admin
   AND NOT applicant.active AND NOT applicant.is_admin;
$function$;