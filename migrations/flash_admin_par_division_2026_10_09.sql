-- Admin national : envoi vers une division, avec le même ciblage pour l'affichage et les e-mails.
-- Un message local par unité membre, dans une seule transaction.
CREATE OR REPLACE FUNCTION public.pointage_admin_create_division_flash(
 p_batch_id uuid,p_division_id uuid,p_title text,p_body text,
 p_start timestamptz,p_end timestamptz,p_email boolean
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE u record; total integer:=0;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=auth.uid() AND p.active AND p.is_admin)
 THEN RAISE EXCEPTION 'Accès administrateur national requis' USING ERRCODE='42501'; END IF;
 IF p_batch_id IS NULL OR p_division_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.pointage_divisions d WHERE d.id=p_division_id AND d.active)
 THEN RAISE EXCEPTION 'Division active et identifiant de lot requis'; END IF;
 FOR u IN SELECT id FROM public.units WHERE active AND upper(name)<>'ADMIN'
   AND division_id=p_division_id ORDER BY id LOOP
   PERFORM pointage_private.create_unit_flash_message(
       md5(p_batch_id::text||u.id::text)::uuid,p_title,p_body,p_start,p_end,p_email,u.id);
   total:=total+1;
 END LOOP;
 IF total=0 THEN RAISE EXCEPTION 'Cette division ne contient aucune unité active'; END IF;
 RETURN total;
END;$fn$;
REVOKE ALL ON FUNCTION public.pointage_admin_create_division_flash(uuid,uuid,text,text,timestamptz,timestamptz,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_admin_create_division_flash(uuid,uuid,text,text,timestamptz,timestamptz,boolean) TO authenticated;