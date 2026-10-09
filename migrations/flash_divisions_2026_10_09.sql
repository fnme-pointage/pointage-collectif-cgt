-- Messages flash : gestion limitée aux unités de la division autorisée.
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
    WHERE id=auth.uid() AND active AND (is_admin OR (p_unit_id IS NOT NULL AND public.pointage_manager_unit_allowed(p_unit_id)))
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
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND (is_admin OR is_unit_manager OR is_division_manager)) THEN RAISE EXCEPTION 'Accès administrateur requis' USING ERRCODE='42501';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC),'[]'::jsonb) INTO result FROM (
 SELECT m.*,count(q.id)::integer AS email_total,count(q.id) FILTER(WHERE q.status='sent')::integer AS email_sent,
 count(q.id) FILTER(WHERE q.status IN('pending','sending') AND m.cancelled_at IS NULL AND m.ends_at>now())::integer AS email_pending,
 count(q.id) FILTER(WHERE q.status='failed')::integer AS email_failed,
 count(q.id) FILTER(WHERE q.status='skipped' OR (q.status IN('pending','sending') AND (m.cancelled_at IS NOT NULL OR m.ends_at<=now())))::integer AS email_skipped
 FROM public.pointage_flash_messages m LEFT JOIN pointage_private.flash_email_notifications q ON q.message_id=m.id WHERE EXISTS (SELECT 1 FROM public.profiles p WHERE p.id=auth.uid() AND p.active AND (p.is_admin OR (m.unit_id IS NOT NULL AND public.pointage_manager_unit_allowed(m.unit_id)))) GROUP BY m.id ORDER BY m.created_at DESC LIMIT 100) t;
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
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND (is_admin OR public.pointage_manager_unit_allowed((SELECT m.unit_id FROM public.pointage_flash_messages m WHERE m.id=p_id)))) THEN RAISE EXCEPTION 'Accès administrateur requis' USING ERRCODE='42501';END IF;
 UPDATE public.pointage_flash_messages SET cancelled_at=coalesce(cancelled_at,now()) WHERE id=p_id;
 UPDATE pointage_private.flash_email_notifications SET status='skipped',claim_id=NULL WHERE message_id=p_id AND status IN('pending','sending');
END;
$function$
;
