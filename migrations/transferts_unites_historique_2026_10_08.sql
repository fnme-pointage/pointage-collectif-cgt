-- Transferts entre unités : conservation intégrale des historiques par unité d'origine.
-- Seul Admin peut transférer, et aucun pointage du mois courant ne peut être partagé.
CREATE TABLE IF NOT EXISTS public.pointage_unit_transfers (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
 from_unit_id uuid NOT NULL REFERENCES public.units(id),
 to_unit_id uuid NOT NULL REFERENCES public.units(id),
 effective_date date NOT NULL,
 performed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
 performed_at timestamptz NOT NULL DEFAULT now(),
 old_role text NOT NULL,
 new_role text NOT NULL,
 CHECK(from_unit_id<>to_unit_id)
);
CREATE INDEX IF NOT EXISTS pointage_unit_transfers_user_idx ON public.pointage_unit_transfers(user_id,performed_at DESC);
ALTER TABLE public.pointage_unit_transfers ENABLE ROW LEVEL SECURITY;
CREATE POLICY unit_transfers_admin_read ON public.pointage_unit_transfers FOR SELECT TO authenticated
 USING ((SELECT public.pointage_is_admin()));
GRANT SELECT ON public.pointage_unit_transfers TO authenticated;

-- La colonne (user_id,unit_id) dans les historiques doit représenter l'unité AU MOMENT du pointage.
-- Les deux FKs composées rendaient impossible une mutation sans perte.
ALTER TABLE public.entries DROP CONSTRAINT entries_user_unit_fk;
ALTER TABLE public.submissions DROP CONSTRAINT submissions_user_unit_fk;

-- Protéger explicitement contre toute saisie créée ou déplacée hors de l'unité d'affectation
-- courante. Des écritures historiques non modifiées restent intactes dans leur unité.
CREATE OR REPLACE FUNCTION public.pointage_guard_entry_unit()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $body$
BEGIN
  IF TG_OP='INSERT' OR
     NEW.user_id IS DISTINCT FROM OLD.user_id OR
     NEW.unit_id IS DISTINCT FROM OLD.unit_id OR
     NEW.month_key IS DISTINCT FROM OLD.month_key
  THEN
    IF NOT EXISTS (SELECT 1 FROM public.profiles p
                   WHERE p.id=NEW.user_id AND p.unit_id=NEW.unit_id)
    THEN RAISE EXCEPTION 'Le pointage doit appartenir à l’unité actuelle du compte' USING ERRCODE='42501'; END IF;
  END IF;
  RETURN NEW;
END;$body$;
DROP TRIGGER IF EXISTS pointage_entries_guard_unit ON public.entries;
CREATE TRIGGER pointage_entries_guard_unit BEFORE INSERT OR UPDATE ON public.entries
 FOR EACH ROW EXECUTE FUNCTION public.pointage_guard_entry_unit();
DROP TRIGGER IF EXISTS pointage_submissions_guard_unit ON public.submissions;
CREATE TRIGGER pointage_submissions_guard_unit BEFORE INSERT OR UPDATE ON public.submissions
 FOR EACH ROW EXECUTE FUNCTION public.pointage_guard_entry_unit();

-- Le responsable voit les noms des personnes historiquement pointées dans son unité
-- sans obtenir le droit de gérer ces profils après leur départ.
CREATE OR REPLACE FUNCTION public.pointage_manager_has_history(p_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $body$
 SELECT EXISTS (
   SELECT 1 FROM public.profiles manager
   WHERE manager.id=auth.uid() AND manager.active AND manager.is_unit_manager AND NOT manager.is_admin
     AND (EXISTS(SELECT 1 FROM public.entries e WHERE e.user_id=p_user_id AND e.unit_id=manager.unit_id)
       OR EXISTS(SELECT 1 FROM public.submissions s WHERE s.user_id=p_user_id AND s.unit_id=manager.unit_id))
 );$body$;
REVOKE ALL ON FUNCTION public.pointage_manager_has_history(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_manager_has_history(uuid) TO authenticated;
CREATE POLICY profiles_manager_historical_read ON public.profiles FOR SELECT TO authenticated
 USING (NOT is_admin AND public.pointage_manager_has_history(id));

-- Les lectures propres à l'utilisateur restent attachées à son unité actuelle;
-- les archives demeurent visibles dans les suivis historiques de l'unité d'origine.
CREATE OR REPLACE FUNCTION public.pointage_admin_transfer_user(
  p_user_id uuid,p_to_unit_id uuid,p_effective_date date,p_role text DEFAULT 'user'
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $body$
DECLARE oldp public.profiles%ROWTYPE; target public.units%ROWTYPE; current_key text; transfer_id bigint;
BEGIN
 IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND is_admin)
 THEN RAISE EXCEPTION 'Accès administrateur requis' USING ERRCODE='42501'; END IF;
 IF p_user_id=auth.uid() THEN RAISE EXCEPTION 'Un administrateur ne peut pas se transférer'; END IF;
 IF p_role NOT IN ('user','manager') THEN RAISE EXCEPTION 'Profil de destination invalide'; END IF;
 IF p_effective_date IS DISTINCT FROM current_date THEN
   RAISE EXCEPTION 'Le transfert prend effet immédiatement : sélectionne la date du jour';
 END IF;
 SELECT * INTO oldp FROM public.profiles WHERE id=p_user_id FOR UPDATE;
 IF NOT FOUND OR oldp.is_admin THEN RAISE EXCEPTION 'Seuls les comptes non administrateurs sont transférables'; END IF;
 SELECT * INTO target FROM public.units WHERE id=p_to_unit_id AND active AND upper(name)<>'ADMIN';
 IF NOT FOUND THEN RAISE EXCEPTION 'Unité de destination invalide'; END IF;
 IF oldp.unit_id=p_to_unit_id THEN RAISE EXCEPTION 'Ce compte est déjà dans cette unité'; END IF;
 current_key:=to_char(current_date,'YYYY-MM');
 IF EXISTS (SELECT 1 FROM public.entries WHERE user_id=p_user_id AND month_key=current_key)
    OR EXISTS (SELECT 1 FROM public.submissions WHERE user_id=p_user_id AND month_key=current_key)
 THEN RAISE EXCEPTION 'Ce compte a déjà des pointages ce mois-ci : transfert possible au début du mois suivant avant toute nouvelle saisie'; END IF;
 INSERT INTO public.pointage_unit_transfers(user_id,from_unit_id,to_unit_id,effective_date,performed_by,old_role,new_role)
 VALUES (p_user_id,oldp.unit_id,p_to_unit_id,p_effective_date,auth.uid(),
 CASE WHEN oldp.is_unit_manager THEN 'manager' ELSE 'user' END,p_role) RETURNING id INTO transfer_id;
 UPDATE public.profiles SET unit_id=p_to_unit_id,is_unit_manager=(p_role='manager'),requested_unit_id=p_to_unit_id
 WHERE id=p_user_id;
 RETURN jsonb_build_object('transfer_id',transfer_id,'from_unit_id',oldp.unit_id,'to_unit_id',p_to_unit_id,'effective_date',p_effective_date);
END;$body$;
REVOKE ALL ON FUNCTION public.pointage_admin_transfer_user(uuid,uuid,date,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_admin_transfer_user(uuid,uuid,date,text) TO authenticated;
