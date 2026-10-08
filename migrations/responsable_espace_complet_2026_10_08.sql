-- Migration : environnement complet des responsables, périmètre limité à leur unité.
-- Tous les droits sont vérifiés côté PostgreSQL, indépendamment de l'interface.
CREATE OR REPLACE FUNCTION public.pointage_manager_unit_allowed(p_unit_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $body$
  SELECT EXISTS(SELECT 1 FROM public.profiles p
    WHERE p.id=auth.uid() AND p.active AND p.is_unit_manager AND NOT p.is_admin
      AND p.unit_id=p_unit_id AND p_unit_id IS NOT NULL)
$body$;
REVOKE ALL ON FUNCTION public.pointage_manager_unit_allowed(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pointage_manager_unit_allowed(uuid) TO authenticated;

CREATE POLICY profiles_manager_unit_read ON public.profiles FOR SELECT TO authenticated
  USING (public.pointage_manager_unit_allowed(unit_id) AND NOT is_admin);
CREATE POLICY entries_manager_unit_read ON public.entries FOR SELECT TO authenticated
  USING (public.pointage_manager_unit_allowed(unit_id));
CREATE POLICY submissions_manager_unit_read ON public.submissions FOR SELECT TO authenticated
  USING (public.pointage_manager_unit_allowed(unit_id));
CREATE POLICY months_manager_unit_update ON public.months FOR UPDATE TO authenticated
  USING (public.pointage_manager_unit_allowed(unit_id))
  WITH CHECK (public.pointage_manager_unit_allowed(unit_id));

CREATE OR REPLACE FUNCTION public.pointage_manager_update_member(
  p_user_id uuid,p_full_name text,p_role text,p_active boolean
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $body$
DECLARE caller public.profiles%ROWTYPE; target public.profiles%ROWTYPE;
BEGIN
  SELECT * INTO caller FROM public.profiles
    WHERE id=auth.uid() AND active AND is_unit_manager AND NOT is_admin;
  IF NOT FOUND THEN RAISE EXCEPTION 'Accès responsable requis' USING ERRCODE='42501'; END IF;
  IF p_role NOT IN ('user','manager') OR p_active IS NULL
     OR p_full_name IS NULL OR length(btrim(p_full_name)) NOT BETWEEN 1 AND 150
  THEN RAISE EXCEPTION 'Nom ou profil incorrect'; END IF;
  SELECT * INTO target FROM public.profiles WHERE id=p_user_id FOR UPDATE;
  IF NOT FOUND OR target.unit_id IS DISTINCT FROM caller.unit_id OR target.is_admin
  THEN RAISE EXCEPTION 'Utilisateur hors de votre unité' USING ERRCODE='42501'; END IF;
  IF p_user_id=auth.uid() AND (p_role<>'manager' OR NOT p_active)
  THEN RAISE EXCEPTION 'Impossible de désactiver ou de rétrograder son propre compte responsable'; END IF;
  UPDATE public.profiles SET full_name=btrim(p_full_name),active=p_active,
     is_unit_manager=(p_role='manager')
   WHERE id=p_user_id AND unit_id=caller.unit_id AND NOT is_admin;
END;
$body$;
REVOKE ALL ON FUNCTION public.pointage_manager_update_member(uuid,text,text,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_manager_update_member(uuid,text,text,boolean) TO authenticated;

-- Documents PDF de l'unité : interdiction des changements nationaux.
CREATE POLICY documents_manager_unit_insert ON public.pointage_documents
  FOR INSERT TO authenticated WITH CHECK (unit_id IS NOT NULL AND public.pointage_manager_unit_allowed(unit_id));
CREATE POLICY documents_manager_unit_delete ON public.pointage_documents
  FOR DELETE TO authenticated USING (unit_id IS NOT NULL AND public.pointage_manager_unit_allowed(unit_id));
-- Fichiers des responsables rangés sous le préfixe UUID de leur unité.
CREATE POLICY pointage_pdfs_manager_unit_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK(bucket_id='pointage-documents'
    AND EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=auth.uid() AND p.active
       AND p.is_unit_manager AND NOT p.is_admin AND
       name LIKE p.unit_id::text || '/%.pdf'));
CREATE POLICY pointage_pdfs_manager_unit_delete ON storage.objects FOR DELETE TO authenticated
  USING(bucket_id='pointage-documents'
    AND (EXISTS(SELECT 1 FROM public.pointage_documents d
      WHERE d.file_path=name AND d.unit_id IS NOT NULL AND public.pointage_manager_unit_allowed(d.unit_id))
      OR EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=auth.uid() AND p.active
         AND p.is_unit_manager AND NOT p.is_admin
         AND name LIKE p.unit_id::text || '/%.pdf')));

-- Fonctions flash existantes : Admin partout, responsables sur leur unité exclusivement.
CREATE OR REPLACE FUNCTION pointage_private.create_unit_flash_message(p_id uuid, p_title text, p_body text, p_start timestamp with time zone, p_end timestamp with time zone, p_email boolean, p_unit_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  existing public.pointage_flash_messages;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id=auth.uid() AND active AND (is_admin OR (is_unit_manager AND p_unit_id IS NOT NULL AND unit_id=p_unit_id))
  ) THEN
    RAISE EXCEPTION 'Accès administrateur requis' USING ERRCODE='42501';
  END IF;

  IF p_unit_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.units
    WHERE id=p_unit_id AND active AND upper(name)<>'ADMIN'
  ) THEN
    RAISE EXCEPTION 'Unité destinataire invalide ou inactive';
  END IF;

  IF p_id IS NULL OR p_title IS NULL OR p_body IS NULL OR
     p_start IS NULL OR p_end IS NULL OR p_email IS NULL OR
     p_end<=now() OR p_end<=p_start OR
     length(btrim(p_title)) NOT BETWEEN 1 AND 160 OR
     strpos(p_title,chr(10))>0 OR strpos(p_title,chr(13))>0 OR
     length(btrim(p_body)) NOT BETWEEN 1 AND 5000
  THEN
    RAISE EXCEPTION 'Renseigne le titre, le message et une période valide.';
  END IF;

  -- Evite un double envoi en cas de nouvelle tentative avec le même UUID.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_id::text,0));
  SELECT * INTO existing FROM public.pointage_flash_messages WHERE id=p_id;
  IF FOUND THEN
    IF existing.created_by IS DISTINCT FROM auth.uid() OR
       existing.title IS DISTINCT FROM btrim(p_title) OR
       existing.body IS DISTINCT FROM btrim(p_body) OR
       existing.starts_at IS DISTINCT FROM p_start OR
       existing.ends_at IS DISTINCT FROM p_end OR
       existing.send_email IS DISTINCT FROM p_email OR
       existing.unit_id IS DISTINCT FROM p_unit_id
    THEN
      RAISE EXCEPTION 'Ce message existe déjà avec un autre contenu.';
    END IF;
    RETURN p_id;
  END IF;

  INSERT INTO public.pointage_flash_messages(
    id,title,body,starts_at,ends_at,send_email,created_by,unit_id
  ) VALUES (
    p_id,btrim(p_title),btrim(p_body),p_start,p_end,p_email,auth.uid(),p_unit_id
  );

  IF p_email THEN
    INSERT INTO pointage_private.flash_email_notifications(message_id,user_id,next_attempt_at)
    SELECT p_id,p.id,greatest(now(),p_start)
    FROM public.profiles p
    JOIN auth.users a ON a.id=p.id
    JOIN public.units u ON u.id=p.unit_id
    WHERE p.active AND NOT p.is_admin AND u.active AND upper(u.name)<>'ADMIN'
      AND a.email_confirmed_at IS NOT NULL AND a.email IS NOT NULL
      AND (p_unit_id IS NULL OR p.unit_id=p_unit_id);
    PERFORM pointage_private.dispatch_flash_notifications();
  END IF;
  RETURN p_id;
END;
$function$
;
CREATE OR REPLACE FUNCTION pointage_private.list_flash_messages()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND (is_admin OR is_unit_manager)) THEN RAISE EXCEPTION 'Accès administrateur requis' USING ERRCODE='42501';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC),'[]'::jsonb) INTO result FROM (
 SELECT m.*,count(q.id)::integer AS email_total,count(q.id) FILTER(WHERE q.status='sent')::integer AS email_sent,
 count(q.id) FILTER(WHERE q.status IN('pending','sending') AND m.cancelled_at IS NULL AND m.ends_at>now())::integer AS email_pending,
 count(q.id) FILTER(WHERE q.status='failed')::integer AS email_failed,
 count(q.id) FILTER(WHERE q.status='skipped' OR (q.status IN('pending','sending') AND (m.cancelled_at IS NOT NULL OR m.ends_at<=now())))::integer AS email_skipped
 FROM public.pointage_flash_messages m LEFT JOIN pointage_private.flash_email_notifications q ON q.message_id=m.id WHERE EXISTS (SELECT 1 FROM public.profiles p WHERE p.id=auth.uid() AND p.active AND (p.is_admin OR (p.is_unit_manager AND m.unit_id=p.unit_id))) GROUP BY m.id ORDER BY m.created_at DESC LIMIT 100) t;
 RETURN jsonb_build_object('server_now',now(),'messages',result);
END;
$function$
;
CREATE OR REPLACE FUNCTION pointage_private.stop_flash_message(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND (is_admin OR (is_unit_manager AND unit_id=(SELECT m.unit_id FROM public.pointage_flash_messages m WHERE m.id=p_id AND m.unit_id IS NOT NULL)))) THEN RAISE EXCEPTION 'Accès administrateur requis' USING ERRCODE='42501';END IF;
 UPDATE public.pointage_flash_messages SET cancelled_at=coalesce(cancelled_at,now()) WHERE id=p_id;
 UPDATE pointage_private.flash_email_notifications SET status='skipped',claim_id=NULL WHERE message_id=p_id AND status IN('pending','sending');
END;
$function$
;
