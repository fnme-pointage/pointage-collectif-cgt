-- Une tentative initiale et trois reprises maximum par mail de validation.
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
  WHERE q.status IN('pending','sending') AND q.next_attempt_at<=now() AND q.attempts<4
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
 IF NOT cfg.enabled OR NOT EXISTS(SELECT 1 FROM pointage_private.activation_notifications q JOIN public.profiles p ON p.id=q.user_id JOIN auth.users a ON a.id=q.user_id WHERE q.status IN('pending','sending') AND q.attempts<4 AND q.next_attempt_at<=now() AND p.active AND NOT p.is_admin AND a.email_confirmed_at IS NOT NULL) THEN RETURN; END IF;
 PERFORM net.http_post(
  url:='https://gzdqqqdeiladltxfajbm.supabase.co/functions/v1/notify-user-activation',
  headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||cfg.anon_key,'x-pointage-notification-token',cfg.token),
  body:='{}'::jsonb,timeout_milliseconds:=120000);
EXCEPTION WHEN OTHERS THEN RAISE WARNING 'Activation notification unavailable; queued for retry';
END;
$$;
