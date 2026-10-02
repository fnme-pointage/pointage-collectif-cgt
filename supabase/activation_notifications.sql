-- Notifications de première activation : aucune reprise des comptes déjà actifs.
CREATE TABLE pointage_private.activation_notifications (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN('pending','sending','sent')),
 attempts integer NOT NULL DEFAULT 0,
 next_attempt_at timestamptz NOT NULL DEFAULT now(),
 claim_id uuid, created_at timestamptz NOT NULL DEFAULT now(), sent_at timestamptz, last_error text
);
ALTER TABLE pointage_private.activation_notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pointage_private.activation_notifications FROM PUBLIC,anon,authenticated;
GRANT SELECT,UPDATE ON pointage_private.activation_notifications TO service_role;
CREATE INDEX activation_notifications_due ON pointage_private.activation_notifications(next_attempt_at) WHERE status IN('pending','sending');

CREATE FUNCTION pointage_private.claim_activation_notifications(p_token text)
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
REVOKE ALL ON FUNCTION pointage_private.claim_activation_notifications(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION pointage_private.claim_activation_notifications(text) TO service_role;

CREATE FUNCTION public.pointage_claim_activation_notifications(p_token text)
RETURNS TABLE(id uuid,user_id uuid,claim_id uuid,full_name text,email text,unit_name text)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM pointage_private.claim_activation_notifications(p_token);
$$;
REVOKE ALL ON FUNCTION public.pointage_claim_activation_notifications(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pointage_claim_activation_notifications(text) TO service_role;

CREATE FUNCTION public.pointage_finish_activation_notification(p_token text,p_id uuid,p_claim uuid,p_sent boolean,p_error text)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF NOT public.pointage_notification_authorized(p_token) THEN RAISE EXCEPTION 'Unauthorized' USING ERRCODE='42501'; END IF;
 UPDATE pointage_private.activation_notifications q
 SET status=CASE WHEN p_sent THEN 'sent' ELSE 'pending' END,
 sent_at=CASE WHEN p_sent THEN now() ELSE NULL END,claim_id=NULL,
 last_error=CASE WHEN p_sent THEN NULL ELSE left(p_error,40) END,
 next_attempt_at=now()+least(interval '24 hours',interval '15 minutes'*power(2,least(q.attempts-1,7)))
 WHERE q.id=p_id AND q.claim_id=p_claim AND q.status='sending';
END;
$$;
REVOKE ALL ON FUNCTION public.pointage_finish_activation_notification(text,uuid,uuid,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pointage_finish_activation_notification(text,uuid,uuid,boolean,text) TO service_role;

CREATE FUNCTION pointage_private.dispatch_activation_notifications() RETURNS void
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
REVOKE ALL ON FUNCTION pointage_private.dispatch_activation_notifications() FROM PUBLIC,anon,authenticated;
CREATE FUNCTION pointage_private.queue_user_activation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.active AND NOT OLD.active AND NOT NEW.is_admin THEN
  INSERT INTO pointage_private.activation_notifications(user_id) VALUES(NEW.id) ON CONFLICT(user_id) DO NOTHING;
  PERFORM pointage_private.dispatch_activation_notifications();
 END IF;
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION pointage_private.queue_user_activation() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER pointage_notify_user_activation AFTER UPDATE OF active ON public.profiles
 FOR EACH ROW EXECUTE FUNCTION pointage_private.queue_user_activation();
SELECT cron.schedule('pointage-retry-activation-notifications','*/15 * * * *','SELECT pointage_private.dispatch_activation_notifications();');
COMMENT ON TABLE pointage_private.activation_notifications IS 'Première activation uniquement; adresse confirmée issue de auth.users; reprise des échecs, sans rétroactivité.';
