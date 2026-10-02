-- Messages globaux, publication réservée à l'administrateur actif.
CREATE TABLE public.pointage_flash_messages (
 id uuid PRIMARY KEY, title text NOT NULL CHECK(length(btrim(title)) BETWEEN 1 AND 160 AND title !~ E'[\r\n]'),
 body text NOT NULL CHECK(length(btrim(body)) BETWEEN 1 AND 5000),
 starts_at timestamptz NOT NULL, ends_at timestamptz NOT NULL CHECK(ends_at>starts_at),
 send_email boolean NOT NULL DEFAULT false, created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
 created_at timestamptz NOT NULL DEFAULT now(), cancelled_at timestamptz
);
ALTER TABLE public.pointage_flash_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pointage_flash_messages FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.pointage_flash_messages TO authenticated,service_role;
CREATE POLICY flash_read ON public.pointage_flash_messages FOR SELECT TO authenticated USING (
 (SELECT public.current_user_is_admin()) OR
 ((SELECT public.current_user_is_active()) AND cancelled_at IS NULL AND starts_at<=now() AND ends_at>now())
);
CREATE INDEX flash_period ON public.pointage_flash_messages(ends_at) WHERE cancelled_at IS NULL;
CREATE TABLE pointage_private.flash_email_notifications (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), message_id uuid NOT NULL REFERENCES public.pointage_flash_messages(id) ON DELETE CASCADE,
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN('pending','sending','sent','failed','skipped')),
 attempts integer NOT NULL DEFAULT 0, next_attempt_at timestamptz NOT NULL,
 claim_id uuid, sent_at timestamptz, last_error text, UNIQUE(message_id,user_id)
);
ALTER TABLE pointage_private.flash_email_notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pointage_private.flash_email_notifications FROM PUBLIC,anon,authenticated;
GRANT SELECT,UPDATE ON pointage_private.flash_email_notifications TO service_role;
CREATE INDEX flash_email_due ON pointage_private.flash_email_notifications(next_attempt_at) WHERE status IN('pending','sending');

CREATE FUNCTION pointage_private.dispatch_flash_notifications() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE cfg pointage_private.notification_config;
BEGIN
 SELECT * INTO cfg FROM pointage_private.notification_config WHERE singleton;
 IF NOT cfg.enabled OR NOT EXISTS(SELECT 1 FROM pointage_private.flash_email_notifications q JOIN public.pointage_flash_messages m ON m.id=q.message_id WHERE q.status IN('pending','sending') AND q.attempts<2 AND q.next_attempt_at<=now() AND m.cancelled_at IS NULL AND m.starts_at<=now() AND m.ends_at>now()) THEN RETURN; END IF;
 PERFORM net.http_post(url:='https://gzdqqqdeiladltxfajbm.supabase.co/functions/v1/notify-flash-message',
 headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||cfg.anon_key,'x-pointage-notification-token',cfg.token),body:='{}'::jsonb,timeout_milliseconds:=120000);
EXCEPTION WHEN OTHERS THEN RAISE WARNING 'Flash notification unavailable; queued for retry';
END;
$$;
REVOKE ALL ON FUNCTION pointage_private.dispatch_flash_notifications() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION pointage_private.create_flash_message(p_id uuid,p_title text,p_body text,p_start timestamptz,p_end timestamptz,p_email boolean)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE existing public.pointage_flash_messages;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND is_admin) THEN RAISE EXCEPTION 'Accès administrateur requis' USING ERRCODE='42501'; END IF;
 IF p_id IS NULL OR p_title IS NULL OR p_body IS NULL OR p_start IS NULL OR p_end IS NULL OR p_email IS NULL OR p_end<=now() OR p_end<=p_start OR length(btrim(p_title)) NOT BETWEEN 1 AND 160 OR p_title ~ E'[\r\n]' OR length(btrim(p_body)) NOT BETWEEN 1 AND 5000 THEN RAISE EXCEPTION 'Renseigne le titre, le message et une période valide.';END IF;
 -- Une répétition de la même requête ne publie ni ne met en file deux fois.
 PERFORM pg_advisory_xact_lock(hashtextextended(p_id::text,0));
 SELECT * INTO existing FROM public.pointage_flash_messages WHERE id=p_id;
 IF FOUND THEN
  IF existing.created_by IS DISTINCT FROM auth.uid() OR existing.title IS DISTINCT FROM btrim(p_title) OR existing.body IS DISTINCT FROM btrim(p_body) OR existing.starts_at IS DISTINCT FROM p_start OR existing.ends_at IS DISTINCT FROM p_end OR existing.send_email IS DISTINCT FROM p_email THEN RAISE EXCEPTION 'Ce message existe déjà avec un autre contenu.';END IF;
  RETURN p_id;
 END IF;
 INSERT INTO public.pointage_flash_messages(id,title,body,starts_at,ends_at,send_email,created_by) VALUES(p_id,btrim(p_title),btrim(p_body),p_start,p_end,p_email,auth.uid());
 IF p_email THEN
  INSERT INTO pointage_private.flash_email_notifications(message_id,user_id,next_attempt_at)
  SELECT p_id,p.id,greatest(now(),p_start) FROM public.profiles p JOIN auth.users a ON a.id=p.id JOIN public.units u ON u.id=p.unit_id
  WHERE p.active AND NOT p.is_admin AND u.active AND upper(u.name)<>'ADMIN' AND a.email_confirmed_at IS NOT NULL AND a.email IS NOT NULL;
  PERFORM pointage_private.dispatch_flash_notifications();
 END IF;
 RETURN p_id;
END;
$$;
REVOKE ALL ON FUNCTION pointage_private.create_flash_message(uuid,text,text,timestamptz,timestamptz,boolean) FROM PUBLIC,anon;
GRANT USAGE ON SCHEMA pointage_private TO authenticated;
GRANT EXECUTE ON FUNCTION pointage_private.create_flash_message(uuid,text,text,timestamptz,timestamptz,boolean) TO authenticated;
CREATE FUNCTION public.pointage_create_flash_message(p_id uuid,p_title text,p_body text,p_start timestamptz,p_end timestamptz,p_email boolean)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT pointage_private.create_flash_message(p_id,p_title,p_body,p_start,p_end,p_email); $$;
REVOKE ALL ON FUNCTION public.pointage_create_flash_message(uuid,text,text,timestamptz,timestamptz,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_create_flash_message(uuid,text,text,timestamptz,timestamptz,boolean) TO authenticated;

CREATE FUNCTION pointage_private.stop_flash_message(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND is_admin) THEN RAISE EXCEPTION 'Accès administrateur requis' USING ERRCODE='42501';END IF;
 UPDATE public.pointage_flash_messages SET cancelled_at=coalesce(cancelled_at,now()) WHERE id=p_id;
 UPDATE pointage_private.flash_email_notifications SET status='skipped',claim_id=NULL WHERE message_id=p_id AND status IN('pending','sending');
END;
$$;
REVOKE ALL ON FUNCTION pointage_private.stop_flash_message(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION pointage_private.stop_flash_message(uuid) TO authenticated;
CREATE FUNCTION public.pointage_stop_flash_message(p_id uuid) RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT pointage_private.stop_flash_message(p_id); $$;
REVOKE ALL ON FUNCTION public.pointage_stop_flash_message(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_stop_flash_message(uuid) TO authenticated;

CREATE FUNCTION public.pointage_get_flash_messages() RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT jsonb_build_object('server_now',now(),'messages',coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.starts_at DESC),'[]'::jsonb)) FROM public.pointage_flash_messages m WHERE m.cancelled_at IS NULL AND m.starts_at<=now() AND m.ends_at>now();
$$;
REVOKE ALL ON FUNCTION public.pointage_get_flash_messages() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_get_flash_messages() TO authenticated;
CREATE FUNCTION pointage_private.list_flash_messages() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND is_admin) THEN RAISE EXCEPTION 'Accès administrateur requis' USING ERRCODE='42501';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC),'[]'::jsonb) INTO result FROM (
 SELECT m.*,count(q.id)::integer AS email_total,count(q.id) FILTER(WHERE q.status='sent')::integer AS email_sent,
 count(q.id) FILTER(WHERE q.status IN('pending','sending') AND m.cancelled_at IS NULL AND m.ends_at>now())::integer AS email_pending,
 count(q.id) FILTER(WHERE q.status='failed')::integer AS email_failed,
 count(q.id) FILTER(WHERE q.status='skipped' OR (q.status IN('pending','sending') AND (m.cancelled_at IS NOT NULL OR m.ends_at<=now())))::integer AS email_skipped
 FROM public.pointage_flash_messages m LEFT JOIN pointage_private.flash_email_notifications q ON q.message_id=m.id GROUP BY m.id ORDER BY m.created_at DESC LIMIT 100) t;
 RETURN jsonb_build_object('server_now',now(),'messages',result);
END;
$$;
REVOKE ALL ON FUNCTION pointage_private.list_flash_messages() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION pointage_private.list_flash_messages() TO authenticated;
CREATE FUNCTION public.pointage_list_flash_messages() RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT pointage_private.list_flash_messages(); $$;
REVOKE ALL ON FUNCTION public.pointage_list_flash_messages() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_list_flash_messages() TO authenticated;

CREATE FUNCTION pointage_private.claim_flash_notifications(p_token text)
RETURNS TABLE(id uuid,user_id uuid,claim_id uuid,message_id uuid,email text,title text,body text,ends_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.pointage_notification_authorized(p_token) THEN RAISE EXCEPTION 'Unauthorized' USING ERRCODE='42501';END IF;
 UPDATE pointage_private.flash_email_notifications q SET status='skipped',claim_id=NULL FROM public.pointage_flash_messages m
 WHERE q.message_id=m.id AND q.status IN('pending','sending') AND (m.cancelled_at IS NOT NULL OR m.ends_at<=now() OR NOT EXISTS(SELECT 1 FROM public.profiles p JOIN auth.users a ON a.id=p.id WHERE p.id=q.user_id AND p.active AND NOT p.is_admin AND a.email_confirmed_at IS NOT NULL));
 RETURN QUERY WITH due AS (
 SELECT q.id FROM pointage_private.flash_email_notifications q JOIN public.pointage_flash_messages m ON m.id=q.message_id
 WHERE q.status IN('pending','sending') AND q.attempts<2 AND q.next_attempt_at<=now() AND m.cancelled_at IS NULL AND m.starts_at<=now() AND m.ends_at>now()
 ORDER BY q.next_attempt_at,q.id FOR UPDATE OF q SKIP LOCKED LIMIT 5
 ),claimed AS (
 UPDATE pointage_private.flash_email_notifications q SET status='sending',attempts=q.attempts+1,claim_id=gen_random_uuid(),next_attempt_at=now()+interval '15 minutes' FROM due WHERE due.id=q.id RETURNING q.*)
 SELECT c.id,c.user_id,c.claim_id,c.message_id,a.email::text,m.title,m.body,m.ends_at FROM claimed c JOIN auth.users a ON a.id=c.user_id JOIN public.pointage_flash_messages m ON m.id=c.message_id;
END;
$$;
REVOKE ALL ON FUNCTION pointage_private.claim_flash_notifications(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION pointage_private.claim_flash_notifications(text) TO service_role;
CREATE FUNCTION public.pointage_claim_flash_notifications(p_token text)
RETURNS TABLE(id uuid,user_id uuid,claim_id uuid,message_id uuid,email text,title text,body text,ends_at timestamptz)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT * FROM pointage_private.claim_flash_notifications(p_token); $$;
REVOKE ALL ON FUNCTION public.pointage_claim_flash_notifications(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pointage_claim_flash_notifications(text) TO service_role;
CREATE FUNCTION public.pointage_finish_flash_notification(p_token text,p_id uuid,p_claim uuid,p_sent boolean,p_error text) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF NOT public.pointage_notification_authorized(p_token) THEN RAISE EXCEPTION 'Unauthorized' USING ERRCODE='42501';END IF;
 UPDATE pointage_private.flash_email_notifications q SET status=CASE WHEN p_sent THEN 'sent' WHEN q.attempts>=2 THEN 'failed' ELSE 'pending' END,
 sent_at=CASE WHEN p_sent THEN now() ELSE NULL END,claim_id=NULL,last_error=CASE WHEN p_sent THEN NULL ELSE left(p_error,40) END,
 next_attempt_at=now()+interval '15 minutes'*power(2,least(q.attempts-1,2)) WHERE q.id=p_id AND q.claim_id=p_claim AND q.status='sending';
END;
$$;
REVOKE ALL ON FUNCTION public.pointage_finish_flash_notification(text,uuid,uuid,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pointage_finish_flash_notification(text,uuid,uuid,boolean,text) TO service_role;
SELECT cron.schedule('pointage-flash-notifications','* * * * *','SELECT pointage_private.dispatch_flash_notifications();');
