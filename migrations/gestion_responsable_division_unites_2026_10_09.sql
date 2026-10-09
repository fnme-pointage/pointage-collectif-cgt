-- Autoriser le Responsable de division dans les seules unités de sa division.
-- La vérification est recalculée depuis les profils actifs, jamais depuis le navigateur.
CREATE OR REPLACE FUNCTION public.pointage_manager_unit_allowed(p_unit_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $f$
 SELECT EXISTS (
   SELECT 1 FROM public.profiles p
   WHERE p.id=auth.uid() AND p.active AND NOT p.is_admin
     AND ( (p.is_unit_manager AND p.unit_id=p_unit_id)
       OR (p.is_division_manager AND p.managed_division_id IS NOT NULL
          AND EXISTS (SELECT 1 FROM public.units own_unit
             WHERE own_unit.id=p.unit_id AND own_unit.division_id=p.managed_division_id)
          AND EXISTS (SELECT 1 FROM public.units target
             WHERE target.id=p_unit_id AND target.active AND target.division_id=p.managed_division_id)))
 );
$f$;

-- Lecture des mois et des codes des unités gérées.
CREATE POLICY months_division_read ON public.months FOR SELECT TO authenticated
 USING (public.pointage_manager_unit_allowed(unit_id));
CREATE POLICY codes_division_read ON public.month_codes FOR SELECT TO authenticated
 USING (public.pointage_manager_unit_allowed(unit_id));
CREATE POLICY documents_division_read ON public.pointage_documents FOR SELECT TO authenticated
 USING (unit_id IS NOT NULL AND public.pointage_manager_unit_allowed(unit_id));

-- Un responsable peut modifier les membres de l'unité sélectionnée de sa division,
-- mais jamais attribuer le rôle de Responsable de division ni modifier un Admin.
CREATE OR REPLACE FUNCTION public.pointage_manager_update_member(p_user_id uuid,p_full_name text,p_role text,p_active boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $f$
DECLARE caller public.profiles%ROWTYPE; target public.profiles%ROWTYPE;
BEGIN
 SELECT * INTO caller FROM public.profiles WHERE id=auth.uid() AND active AND NOT is_admin
  AND (is_unit_manager OR is_division_manager);
 IF NOT FOUND THEN RAISE EXCEPTION 'Accès responsable requis' USING ERRCODE='42501'; END IF;
 IF p_role NOT IN ('user','manager') OR p_active IS NULL OR p_full_name IS NULL
  OR length(btrim(p_full_name)) NOT BETWEEN 1 AND 150 THEN
   RAISE EXCEPTION 'Nom ou profil incorrect'; END IF;
 SELECT * INTO target FROM public.profiles WHERE id=p_user_id FOR UPDATE;
 IF NOT FOUND OR target.is_admin OR NOT public.pointage_manager_unit_allowed(target.unit_id)
 THEN RAISE EXCEPTION 'Utilisateur hors de votre périmètre' USING ERRCODE='42501'; END IF;
 IF p_user_id=auth.uid() AND (NOT p_active OR (caller.is_unit_manager AND p_role<>'manager' AND NOT caller.is_division_manager))
 THEN RAISE EXCEPTION 'Impossible de retirer votre dernier rôle de gestion ou de désactiver votre compte'; END IF;
 UPDATE public.profiles SET full_name=btrim(p_full_name),active=p_active,
 is_unit_manager=(p_role='manager') WHERE id=p_user_id;
END;$f$;

-- La liste des profils hors de l'unité propre reste exclusivement en lecture RLS.
-- Les écritures de profils continuent à utiliser les RPC contrôlées.

-- Supabase Storage : autoriser les PDF uniquement sous le préfixe UUID
-- d'une unité explicitement administrée par le responsable.
CREATE POLICY pointage_pdfs_division_insert ON storage.objects
 FOR INSERT TO authenticated WITH CHECK (
  bucket_id='pointage-documents'
  AND EXISTS(SELECT 1 FROM public.units u WHERE name LIKE u.id::text||'/%.pdf'
    AND public.pointage_manager_unit_allowed(u.id))
 );
CREATE POLICY pointage_pdfs_division_upload_read ON storage.objects
 FOR SELECT TO authenticated USING (
  bucket_id='pointage-documents'
  AND EXISTS(SELECT 1 FROM public.units u WHERE name LIKE u.id::text||'/%.pdf'
    AND public.pointage_manager_unit_allowed(u.id))
 );
CREATE POLICY pointage_pdfs_division_delete ON storage.objects
 FOR DELETE TO authenticated USING (
  bucket_id='pointage-documents'
  AND EXISTS(SELECT 1 FROM public.pointage_documents d
   WHERE d.file_path=name AND d.unit_id IS NOT NULL
      AND public.pointage_manager_unit_allowed(d.unit_id))
 );
