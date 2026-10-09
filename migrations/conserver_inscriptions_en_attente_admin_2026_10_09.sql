-- Tant que l'inscription n'est pas active, conserver son unite d'attente.
-- Enregistrer uniquement l'unite demandee ; l'affectation effective intervient a l'activation.
DO $fix$
DECLARE definition text;
BEGIN
 SELECT pg_get_functiondef(oid) INTO definition
 FROM pg_proc WHERE proname='pointage_division_review_signup' AND pronamespace='public'::regnamespace;
 IF definition IS NULL THEN RAISE EXCEPTION 'Fonction absente'; END IF;
 definition:=replace(definition,
  'unit_id=p_unit_id,is_unit_manager=(p_role=''manager''),active=p_active',
  'unit_id=CASE WHEN p_active THEN p_unit_id ELSE applicant.unit_id END,requested_unit_id=p_unit_id,is_unit_manager=(p_role=''manager''),active=p_active');
 EXECUTE definition;
END $fix$;
