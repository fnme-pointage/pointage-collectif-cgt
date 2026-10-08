-- Evolution rétrocompatible : messages flash nationaux ou ciblés par unité.
-- Les messages existants gardent unit_id NULL (diffusion nationale).
-- Ancienne RPC de création à 6 paramètres conservée pour l'application officielle.
BEGIN;

ALTER TABLE public.pointage_flash_messages
  ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
CREATE INDEX IF NOT EXISTS pointage_flash_messages_unit_period_idx
  ON public.pointage_flash_messages (unit_id, starts_at, ends_at);

CREATE OR REPLACE FUNCTION pointage_private.create_unit_flash_message(
  p_id uuid, p_title text, p_body text, p_start timestamptz,
  p_end timestamptz, p_email boolean, p_unit_id uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  existing public.pointage_flash_messages;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id=auth.uid() AND active AND is_admin
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
$function$;

REVOKE ALL ON FUNCTION pointage_private.create_unit_flash_message(
  uuid,text,text,timestamptz,timestamptz,boolean,uuid
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.pointage_create_flash_message(
  p_id uuid,p_title text,p_body text,p_start timestamptz,
  p_end timestamptz,p_email boolean,p_unit_id uuid
) RETURNS uuid
LANGUAGE sql SET search_path TO ''
AS $function$
  SELECT pointage_private.create_unit_flash_message(
    p_id,p_title,p_body,p_start,p_end,p_email,p_unit_id
  );
$function$;

REVOKE ALL ON FUNCTION public.pointage_create_flash_message(
  uuid,text,text,timestamptz,timestamptz,boolean,uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pointage_create_flash_message(
  uuid,text,text,timestamptz,timestamptz,boolean,uuid
) TO authenticated;

-- L'ancienne RPC à 6 arguments reste intacte et continue de créer
-- uniquement des messages nationaux. Aucune rupture pour l'application courante.

DROP POLICY IF EXISTS flash_read ON public.pointage_flash_messages;
CREATE POLICY flash_read ON public.pointage_flash_messages
FOR SELECT TO authenticated
USING (
  (SELECT public.current_user_is_admin())
  OR (
    (SELECT public.current_user_is_active())
    AND cancelled_at IS NULL
    AND starts_at<=now()
    AND ends_at>now()
    AND (
      unit_id IS NULL OR unit_id=(
        SELECT p.unit_id FROM public.profiles p
        WHERE p.id=(SELECT auth.uid()) AND p.active
      )
    )
  )
);

-- RPC d'affichage : les utilisateurs ne reçoivent que les messages
-- nationaux ET ceux de leur unité, avec l'origine indiquée.
CREATE OR REPLACE FUNCTION public.pointage_get_flash_messages()
RETURNS jsonb
LANGUAGE sql SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'server_now',now(),
    'messages',coalesce(
      jsonb_agg(to_jsonb(m)||jsonb_build_object('unit_name',u.name)
                ORDER BY m.starts_at DESC),
      '[]'::jsonb
    )
  )
  FROM public.pointage_flash_messages m
  LEFT JOIN public.units u ON u.id=m.unit_id
  WHERE m.cancelled_at IS NULL AND m.starts_at<=now() AND m.ends_at>now()
    AND (m.unit_id IS NULL OR m.unit_id=(
      SELECT p.unit_id FROM public.profiles p
      WHERE p.id=auth.uid() AND p.active
    ));
$function$;
COMMIT;
