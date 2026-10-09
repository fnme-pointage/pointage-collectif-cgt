-- Les rôles Utilisateur, Responsable d'unité et Responsable de division se cumulent.
-- L'usage du pointage personnel est implicite pour tout compte actif non Admin.
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS pointage_division_manager_role_check;
ALTER TABLE public.profiles ADD CONSTRAINT pointage_division_manager_role_check
 CHECK (
   (is_division_manager AND managed_division_id IS NOT NULL AND NOT is_admin)
   OR (NOT is_division_manager AND managed_division_id IS NULL)
 );
-- Conserver la règle de sécurité : un responsable de division appartient à sa division,
-- tout en autorisant explicitement le cumul avec la responsabilité d'unité.
CREATE OR REPLACE FUNCTION public.pointage_admin_set_division_manager(p_user_id uuid,p_division_id uuid,p_enabled boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE person public.profiles%ROWTYPE;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND is_admin)
 THEN RAISE EXCEPTION 'Administrateur national requis' USING ERRCODE='42501'; END IF;
 SELECT * INTO person FROM public.profiles WHERE id=p_user_id FOR UPDATE;
 IF NOT FOUND OR person.is_admin OR NOT person.active THEN
   RAISE EXCEPTION 'Utilisateur actif non administrateur requis'; END IF;
 IF p_enabled THEN
  IF p_division_id IS NULL OR NOT EXISTS(
     SELECT 1 FROM public.pointage_divisions WHERE id=p_division_id AND active)
  THEN RAISE EXCEPTION 'Division invalide'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.units WHERE id=person.unit_id AND division_id=p_division_id)
  THEN RAISE EXCEPTION 'Le responsable doit appartenir à sa division'; END IF;
  UPDATE public.profiles SET is_division_manager=true,managed_division_id=p_division_id
  WHERE id=p_user_id;
 ELSE
  UPDATE public.profiles SET is_division_manager=false,managed_division_id=NULL WHERE id=p_user_id;
 END IF;
END;$fn$;

-- Modification atomique des responsabilités cumulables depuis Admin > Utilisateurs.
CREATE OR REPLACE FUNCTION public.pointage_admin_set_combined_roles(
 p_user_id uuid,p_full_name text,p_unit_id uuid,
 p_is_unit_manager boolean,p_division_id uuid DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE oldp public.profiles%ROWTYPE; dest public.units%ROWTYPE;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND is_admin)
 THEN RAISE EXCEPTION 'Administrateur national requis' USING ERRCODE='42501'; END IF;
 IF p_full_name IS NULL OR length(btrim(p_full_name)) NOT BETWEEN 1 AND 150
 OR p_is_unit_manager IS NULL THEN RAISE EXCEPTION 'Nom ou responsabilités incorrects'; END IF;
 SELECT * INTO oldp FROM public.profiles WHERE id=p_user_id FOR UPDATE;
 IF NOT FOUND OR oldp.is_admin THEN
  RAISE EXCEPTION 'Utilise les droits Admin pour modifier un compte administrateur'; END IF;
 SELECT * INTO dest FROM public.units WHERE id=p_unit_id AND active AND upper(name)<>'ADMIN';
 IF NOT FOUND THEN RAISE EXCEPTION 'Unité opérationnelle invalide'; END IF;
 IF oldp.unit_id IS DISTINCT FROM p_unit_id THEN
  RAISE EXCEPTION 'Pour changer d’unité, utilise exclusivement Transférer'; END IF;
 IF p_division_id IS NOT NULL AND NOT EXISTS(
  SELECT 1 FROM public.pointage_divisions WHERE id=p_division_id AND active
  AND id=dest.division_id)
 THEN RAISE EXCEPTION 'La division doit correspondre à l’unité du salarié'; END IF;
 UPDATE public.profiles SET full_name=btrim(p_full_name),
   is_unit_manager=p_is_unit_manager,
   is_division_manager=(p_division_id IS NOT NULL),
   managed_division_id=p_division_id
 WHERE id=p_user_id;
END;$fn$;

-- Un Responsable d'unité conserve uniquement sa compétence locale.
-- Il ne peut pas retirer ou attribuer une fonction de division.
REVOKE ALL ON FUNCTION public.pointage_admin_set_combined_roles(uuid,text,uuid,boolean,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_admin_set_combined_roles(uuid,text,uuid,boolean,uuid) TO authenticated;
