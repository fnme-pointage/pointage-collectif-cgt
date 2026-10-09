-- Les personnes mutées conservent leur présence dans les suivis historiques
-- de la division de leurs anciens pointages (lecture seule du profil).
CREATE OR REPLACE FUNCTION public.pointage_manager_has_history(p_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $f$
 SELECT EXISTS(
  SELECT 1 FROM public.profiles caller WHERE caller.id=auth.uid() AND caller.active AND NOT caller.is_admin
   AND (caller.is_unit_manager OR caller.is_division_manager)
   AND (EXISTS(SELECT 1 FROM public.entries e WHERE e.user_id=p_user_id
                AND public.pointage_manager_unit_allowed(e.unit_id))
        OR EXISTS(SELECT 1 FROM public.submissions s WHERE s.user_id=p_user_id
                AND public.pointage_manager_unit_allowed(s.unit_id)))
 );$f$;
REVOKE ALL ON FUNCTION public.pointage_manager_has_history(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_manager_has_history(uuid) TO authenticated;
