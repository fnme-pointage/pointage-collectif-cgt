-- Projet, non appliqué en production.
-- Ajouter un statut distinct sans modifier les profils actuels.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_unit_manager boolean NOT NULL DEFAULT false;
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_unit_manager_not_admin
  CHECK (NOT (is_admin AND is_unit_manager));

CREATE OR REPLACE FUNCTION public.pointage_admin_update_user_role(
  p_user_id uuid, p_full_name text, p_unit_id uuid, p_role text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $body$
DECLARE
  old_profile public.profiles%ROWTYPE;
  target_unit public.units%ROWTYPE;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id=auth.uid() AND is_admin AND active
  ) THEN
    RAISE EXCEPTION 'Accès administrateur requis' USING ERRCODE='42501';
  END IF;
  IF p_role NOT IN ('user','manager','admin')
     OR p_full_name IS NULL OR length(btrim(p_full_name)) NOT BETWEEN 1 AND 150
  THEN
    RAISE EXCEPTION 'Profil ou nom invalide';
  END IF;

  SELECT * INTO old_profile FROM public.profiles WHERE id=p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Utilisateur introuvable'; END IF;
  SELECT * INTO target_unit FROM public.units WHERE id=p_unit_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unité invalide ou inactive'; END IF;
  IF (p_role='admin') <> (upper(target_unit.name)='ADMIN') THEN
    RAISE EXCEPTION 'Administrateur dans ADMIN, autres profils dans leur unité';
  END IF;

  -- Le responsable national ne peut pas révoquer sa propre session.
  IF old_profile.id=auth.uid() AND p_role<>'admin' THEN
    RAISE EXCEPTION 'Impossible de retirer ses propres droits administrateur';
  END IF;
  -- Empêche toute disparition accidentelle du dernier administrateur.
  IF old_profile.is_admin AND p_role<>'admin' AND
     (SELECT count(*) FROM public.profiles WHERE is_admin AND active)<=1 THEN
    RAISE EXCEPTION 'Le dernier administrateur ne peut pas être rétrogradé';
  END IF;
  -- Les écritures de pointage sont rattachées à l'unité de leur auteur.
  IF old_profile.unit_id IS DISTINCT FROM p_unit_id AND (
    EXISTS (SELECT 1 FROM public.entries WHERE user_id=p_user_id)
    OR EXISTS (SELECT 1 FROM public.submissions WHERE user_id=p_user_id)
  ) THEN
    RAISE EXCEPTION 'Ce compte possède déjà des pointages : changement d’unité interdit';
  END IF;

  UPDATE public.profiles SET
    full_name=btrim(p_full_name),
    unit_id=p_unit_id,
    is_admin=(p_role='admin'),
    is_unit_manager=(p_role='manager')
  WHERE id=p_user_id;
END;
$body$;

REVOKE ALL ON FUNCTION public.pointage_admin_update_user_role(uuid,text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pointage_admin_update_user_role(uuid,text,uuid,text) TO authenticated;
