-- Corrige l'ambiguite PL/pgSQL entre la variable et la colonne division_id.
DO $fix$
DECLARE definition text;
BEGIN
 SELECT pg_get_functiondef(p.oid) INTO definition
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname='pointage_division_review_signup';
 IF definition IS NULL THEN RAISE EXCEPTION 'Fonction introuvable'; END IF;
 definition := replace(definition,'applicant public.profiles%ROWTYPE; division_id uuid;', 'applicant public.profiles%ROWTYPE; v_managed_division_id uuid;');
 definition := replace(definition,'INTO division_id FROM', 'INTO v_managed_division_id FROM');
 definition := replace(definition,'IF division_id IS NULL', 'IF v_managed_division_id IS NULL');
 definition := replace(definition,'=division_id', '=v_managed_division_id');
 EXECUTE definition;
END $fix$;
