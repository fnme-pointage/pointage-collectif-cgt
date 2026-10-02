-- Une tentative initiale et une seule reprise maximum pour les validations et messages flash.
CREATE OR REPLACE FUNCTION pointage_private.claim_activation_notifications(p_token text)
RETURNS TABLE(id uuid,user_id uuid,claim_id uuid,full_name text,email text,unit_name text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.pointage_notification_authorized(p_token) THEN RAISE EXCEPTION 'Unauthorized' USING ERRCODE='42501'; END IF;
 RETURN QUERY WITH due AS (
  SELECT q.id FROM pointage_private.activation_notifications q
  JOIN public.profiles p ON p.id=q.user_id
  JOIN auth.users a ON a.id=q.user_id
  JOIN public.units u ON u.id=p.unit_id
  WHERE q.status IN('pending','sending') AND q.next_attempt_at<=now() AND q.attempts<2
   AND p.active AND NOT p.is_admin AND a.email_confirmed_at IS NOT NULL AND a.email IS NOT NULL AND upper(u.name)<>'ADMIN'
  ORDER BY q.created_at FOR UPDATE OF q SKIP LOCKED LIMIT 3
 ), claimed AS (
  UPDATE pointage_private.activation_notifications q SET status='sending',attempts=q.attempts+1,
   claim_id=gen_random_uuid(),next_attempt_at=now()+interval '15 minutes'
  FROM due WHERE q.id=due.id RETURNING q.id,q.user_id,q.claim_id
 ) SELECT c.id,c.user_id,c.claim_id,p.full_name,a.email::text,u.name FROM claimed c
 JOIN public.profiles p ON p.id=c.user_id JOIN auth.users a ON a.id=c.user_id JOIN public.units u ON u.id=p.unit_id;
END;
$$;

CREATE OR REPLACE FUNCTION pointage_private.dispatch_activation_notifications() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE cfg pointage_private.notification_config;
BEGIN
 SELECT * INTO cfg FROM pointage_private.notification_config WHERE singleton;
 IF NOT cfg.enabled OR NOT EXISTS(SELECT 1 FROM pointage_private.activation_notifications q JOIN public.profiles p ON p.id=q.user_id JOIN auth.users a ON a.id=q.user_id WHERE q.status IN('pending','sending') AND q.attempts<2 AND q.next_attempt_at<=now() AND p.active AND NOT p.is_admin AND a.email_confirmed_at IS NOT NULL) THEN RETURN; END IF;
 PERFORM net.http_post(
  url:='https://gzdqqqdeiladltxfajbm.supabase.co/functions/v1/notify-user-activation',
  headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||cfg.anon_key,'x-pointage-notification-token',cfg.token),
  body:='{}'::jsonb,timeout_milliseconds:=120000);
EXCEPTION WHEN OTHERS THEN RAISE WARNING 'Activation notification unavailable; queued for retry';
END;
$$;

CREATE OR REPLACE FUNCTION pointage_private.dispatch_flash_notifications() RETURNS void
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

CREATE OR REPLACE FUNCTION pointage_private.claim_flash_notifications(p_token text)
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

CREATE OR REPLACE FUNCTION public.pointage_finish_flash_notification(p_token text,p_id uuid,p_claim uuid,p_sent boolean,p_error text) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF NOT public.pointage_notification_authorized(p_token) THEN RAISE EXCEPTION 'Unauthorized' USING ERRCODE='42501';END IF;
 UPDATE pointage_private.flash_email_notifications q SET status=CASE WHEN p_sent THEN 'sent' WHEN q.attempts>=2 THEN 'failed' ELSE 'pending' END,
 sent_at=CASE WHEN p_sent THEN now() ELSE NULL END,claim_id=NULL,last_error=CASE WHEN p_sent THEN NULL ELSE left(p_error,40) END,
 next_attempt_at=now()+interval '15 minutes'*power(2,least(q.attempts-1,2)) WHERE q.id=p_id AND q.claim_id=p_claim AND q.status='sending';
END;
$$;
