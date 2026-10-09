-- Renommage reserve a l'administrateur national. IDs et rattachements preserves.
CREATE OR REPLACE FUNCTION public.pointage_admin_rename_unit(p_unit_id uuid,p_name text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND is_admin) THEN RAISE EXCEPTION 'Administrateur requis' USING ERRCODE='42501'; END IF;
 IF p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Nom invalide'; END IF;
 IF EXISTS(SELECT 1 FROM public.units WHERE id=p_unit_id AND name='ADMIN') THEN RAISE EXCEPTION 'Unite ADMIN reservee'; END IF;
 UPDATE public.units SET name=btrim(p_name) WHERE id=p_unit_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unite introuvable'; END IF;
END; $$;
CREATE OR REPLACE FUNCTION public.pointage_admin_rename_division(p_division_id uuid,p_name text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND is_admin) THEN RAISE EXCEPTION 'Administrateur requis' USING ERRCODE='42501'; END IF;
 IF p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Nom invalide'; END IF;
 UPDATE public.pointage_divisions SET name=btrim(p_name) WHERE id=p_division_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Division introuvable'; END IF;
END; $$;
REVOKE ALL ON FUNCTION public.pointage_admin_rename_unit(uuid,text),public.pointage_admin_rename_division(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_admin_rename_unit(uuid,text),public.pointage_admin_rename_division(uuid,text) TO authenticated;
