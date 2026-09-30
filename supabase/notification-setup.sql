-- Configuration appliquée par migration Supabase ; clé anon à remplacer lors d’une installation neuve.
-- Envois désactivés par défaut jusqu’à configuration et test de POINTAGE_GMAIL_APP_PASSWORD.

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
CREATE SCHEMA IF NOT EXISTS pointage_private;
REVOKE ALL ON SCHEMA pointage_private FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA pointage_private TO service_role;
CREATE TABLE pointage_private.notification_config(
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 enabled boolean NOT NULL DEFAULT false,
 token text NOT NULL DEFAULT (gen_random_uuid()::text || gen_random_uuid()::text),
 anon_key text NOT NULL
);
CREATE TABLE pointage_private.signup_notifications(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN('pending','sending','sent','skipped')),
 attempts integer NOT NULL DEFAULT 0,
 next_attempt_at timestamptz NOT NULL DEFAULT now(),
 claim_id uuid,
 created_at timestamptz NOT NULL DEFAULT now(),
 sent_at timestamptz,
 last_error text
);
ALTER TABLE pointage_private.notification_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE pointage_private.signup_notifications ENABLE ROW LEVEL SECURITY;
GRANT SELECT,UPDATE ON pointage_private.signup_notifications TO service_role;
GRANT SELECT ON pointage_private.notification_config TO service_role;
INSERT INTO pointage_private.notification_config(anon_key) VALUES('__ANON_KEY__');
CREATE INDEX signup_notifications_due ON pointage_private.signup_notifications(next_attempt_at) WHERE status IN('pending','sending');

CREATE FUNCTION public.pointage_notification_authorized(p_token text) RETURNS boolean
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM pointage_private.notification_config WHERE token=p_token);
$$;
REVOKE ALL ON FUNCTION public.pointage_notification_authorized(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pointage_notification_authorized(text) TO service_role;

CREATE FUNCTION public.pointage_claim_signup_notifications(p_token text)
RETURNS TABLE(id uuid,user_id uuid,claim_id uuid,full_name text,requested_unit text)
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF NOT public.pointage_notification_authorized(p_token) THEN RAISE EXCEPTION 'Unauthorized' USING ERRCODE='42501'; END IF;
 UPDATE pointage_private.signup_notifications q SET status='skipped',claim_id=NULL
 WHERE q.status IN('pending','sending') AND NOT EXISTS(
  SELECT 1 FROM public.profiles p
  WHERE p.id=q.user_id AND NOT p.active AND NOT p.is_admin);
 RETURN QUERY
 WITH due AS (
  SELECT q.id FROM pointage_private.signup_notifications q
  WHERE q.status IN('pending','sending') AND q.next_attempt_at<=now() AND q.attempts<10
  ORDER BY q.created_at FOR UPDATE SKIP LOCKED LIMIT 3
 ), claimed AS (
  UPDATE pointage_private.signup_notifications q SET status='sending',attempts=q.attempts+1,
   claim_id=gen_random_uuid(),next_attempt_at=now()+interval '15 minutes'
  FROM due WHERE q.id=due.id RETURNING q.id,q.user_id,q.claim_id
 )
 SELECT c.id,c.user_id,c.claim_id,p.full_name,u.name FROM claimed c
 JOIN public.profiles p ON p.id=c.user_id LEFT JOIN public.units u ON u.id=p.requested_unit_id;
END;
$$;
REVOKE ALL ON FUNCTION public.pointage_claim_signup_notifications(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pointage_claim_signup_notifications(text) TO service_role;

CREATE FUNCTION public.pointage_finish_signup_notification(p_token text,p_id uuid,p_claim uuid,p_sent boolean,p_error text)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF NOT public.pointage_notification_authorized(p_token) THEN RAISE EXCEPTION 'Unauthorized' USING ERRCODE='42501'; END IF;
 UPDATE pointage_private.signup_notifications q
 SET status=CASE WHEN p_sent THEN 'sent' ELSE 'pending' END,
 sent_at=CASE WHEN p_sent THEN now() ELSE NULL END,claim_id=NULL,
 last_error=CASE WHEN p_sent THEN NULL ELSE left(p_error,40) END,
 next_attempt_at=now()+least(interval '24 hours',interval '15 minutes'*power(2,least(q.attempts-1,7)))
 WHERE q.id=p_id AND q.claim_id=p_claim AND q.status='sending';
END;
$$;
REVOKE ALL ON FUNCTION public.pointage_finish_signup_notification(text,uuid,uuid,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pointage_finish_signup_notification(text,uuid,uuid,boolean,text) TO service_role;

CREATE FUNCTION pointage_private.dispatch_signup_notifications() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE cfg pointage_private.notification_config;
BEGIN
 SELECT * INTO cfg FROM pointage_private.notification_config WHERE singleton;
 IF NOT cfg.enabled OR NOT EXISTS(SELECT 1 FROM pointage_private.signup_notifications WHERE status IN('pending','sending') AND attempts<10 AND next_attempt_at<=now()) THEN RETURN; END IF;
 PERFORM net.http_post(
  url:='https://gzdqqqdeiladltxfajbm.supabase.co/functions/v1/notify-admin-signup',
  headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||cfg.anon_key,'x-pointage-notification-token',cfg.token),
  body:='{}'::jsonb,timeout_milliseconds:=120000);
EXCEPTION WHEN OTHERS THEN
 RAISE WARNING 'Notification dispatch unavailable; queued for retry';
END;
$$;
REVOKE ALL ON FUNCTION pointage_private.dispatch_signup_notifications() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION pointage_private.queue_confirmed_signup() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.email_confirmed_at IS NOT NULL AND (TG_OP='INSERT' OR OLD.email_confirmed_at IS NULL)
 AND EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=NEW.id AND NOT p.active AND NOT p.is_admin) THEN
  INSERT INTO pointage_private.signup_notifications(user_id) VALUES(NEW.id) ON CONFLICT(user_id) DO NOTHING;
  PERFORM pointage_private.dispatch_signup_notifications();
 END IF;
 RETURN NEW;
EXCEPTION WHEN OTHERS THEN
 RAISE WARNING 'Signup notification unavailable; account confirmation maintained';
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION pointage_private.queue_confirmed_signup() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER pointage_notify_confirmed_signup AFTER INSERT OR UPDATE OF email_confirmed_at ON auth.users
 FOR EACH ROW EXECUTE FUNCTION pointage_private.queue_confirmed_signup();
SELECT cron.schedule('pointage-retry-signup-notifications','*/15 * * * *','SELECT pointage_private.dispatch_signup_notifications();');
COMMENT ON TABLE pointage_private.signup_notifications IS 'Notifications administrateur après confirmation e-mail; file privée, sans rétroactivité.';
