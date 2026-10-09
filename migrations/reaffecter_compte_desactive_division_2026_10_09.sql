-- Autoriser un responsable de division a reaffecter un compte desactive sans pointages,
-- uniquement entre les unites actives de sa division.
CREATE OR REPLACE FUNCTION public.pointage_division_reassign_inactive(p_user_id uuid,p_unit_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE division_scope uuid; person public.profiles%ROWTYPE;
BEGIN
 SELECT caller.managed_division_id INTO division_scope FROM public.profiles caller
 JOIN public.pointage_divisions d ON d.id=caller.managed_division_id AND d.active
 JOIN public.units home ON home.id=caller.unit_id AND home.division_id=d.id
 WHERE caller.id=auth.uid() AND caller.active AND caller.is_division_manager AND NOT caller.is_admin;
 IF division_scope IS NULL THEN RAISE EXCEPTION 'Responsable de division requis' USING ERRCODE='42501'; END IF;
 SELECT * INTO person FROM public.profiles WHERE id=p_user_id FOR UPDATE;
 IF NOT FOUND OR person.active OR person.is_admin OR person.is_division_manager OR person.id=auth.uid()
 OR NOT EXISTS(SELECT 1 FROM public.units WHERE id=person.unit_id AND division_id=division_scope)
 OR NOT EXISTS(SELECT 1 FROM public.units WHERE id=p_unit_id AND division_id=division_scope AND active)
 THEN RAISE EXCEPTION 'Changement d unite non autorise' USING ERRCODE='42501'; END IF;
 IF EXISTS(SELECT 1 FROM public.entries WHERE user_id=p_user_id)
 OR EXISTS(SELECT 1 FROM public.submissions WHERE user_id=p_user_id)
 THEN RAISE EXCEPTION 'Ce compte possede des pointages. Utiliser un transfert admin pour conserver les historiques.'; END IF;
 UPDATE public.profiles SET unit_id=p_unit_id WHERE id=p_user_id;
END;
$$;
REVOKE ALL ON FUNCTION public.pointage_division_reassign_inactive(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_division_reassign_inactive(uuid,uuid) TO authenticated;
