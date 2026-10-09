-- Publication atomique dans chaque unité d'une division, sans message national.
-- Le serveur détermine le périmètre ; le navigateur ne peut pas ajouter une autre unité.
CREATE OR REPLACE FUNCTION public.pointage_create_division_flash(
 p_batch_id uuid,p_title text,p_body text,p_start timestamptz,p_end timestamptz,p_email boolean
) RETURNS integer LANGUAGE plpgsql SECURITY INVOKER SET search_path TO '' AS $f$
DECLARE caller public.profiles%ROWTYPE; u record; total integer:=0; target_id uuid;
BEGIN
 SELECT * INTO caller FROM public.profiles WHERE id=auth.uid()
  AND active AND is_division_manager AND NOT is_admin;
 IF NOT FOUND OR caller.managed_division_id IS NULL THEN
  RAISE EXCEPTION 'Accès responsable de division requis' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.units o WHERE o.id=caller.unit_id
    AND o.division_id=caller.managed_division_id) THEN
  RAISE EXCEPTION 'Division du responsable incohérente' USING ERRCODE='42501'; END IF;
 IF p_batch_id IS NULL THEN RAISE EXCEPTION 'Identifiant de lot obligatoire'; END IF;
 FOR u IN SELECT id FROM public.units WHERE active AND name<>'ADMIN'
   AND division_id=caller.managed_division_id ORDER BY id LOOP
   target_id:=md5(p_batch_id::text||u.id::text)::uuid;
   PERFORM pointage_private.create_unit_flash_message(
      target_id,p_title,p_body,p_start,p_end,p_email,u.id);
   total:=total+1;
 END LOOP;
 IF total=0 THEN RAISE EXCEPTION 'Aucune unité active dans la division'; END IF;
 RETURN total;
END;$f$;
REVOKE ALL ON FUNCTION public.pointage_create_division_flash(uuid,text,text,timestamptz,timestamptz,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_create_division_flash(uuid,text,text,timestamptz,timestamptz,boolean) TO authenticated;
