-- Mise en place de la hiérarchie nationale > divisions > unités.
-- Pas de transfert de pointages ni d'attribution automatique de droits élevés.
CREATE TABLE IF NOT EXISTS public.pointage_divisions(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 name text NOT NULL UNIQUE CHECK(length(btrim(name)) BETWEEN 2 AND 100),
 active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.pointage_divisions(name) VALUES ('DTEAM'),('DPN')
 ON CONFLICT(name) DO NOTHING;
ALTER TABLE public.units ADD COLUMN IF NOT EXISTS division_id uuid REFERENCES public.pointage_divisions(id);
UPDATE public.units SET division_id=(SELECT id FROM public.pointage_divisions WHERE name='DTEAM')
 WHERE name IN('ULM','UFPI','OPF') AND division_id IS NULL;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS is_division_manager boolean NOT NULL DEFAULT false;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS managed_division_id uuid REFERENCES public.pointage_divisions(id);
ALTER TABLE public.profiles ADD CONSTRAINT pointage_division_manager_role_check
 CHECK ((is_division_manager AND managed_division_id IS NOT NULL AND NOT is_admin AND NOT is_unit_manager)
 OR (NOT is_division_manager AND managed_division_id IS NULL));
CREATE UNIQUE INDEX IF NOT EXISTS pointage_division_one_manager
 ON public.profiles(managed_division_id) WHERE is_division_manager;
ALTER TABLE public.pointage_divisions ENABLE ROW LEVEL SECURITY;
CREATE POLICY pointage_divisions_list ON public.pointage_divisions
 FOR SELECT TO authenticated USING (
   EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=auth.uid() AND p.active
     AND (p.is_admin OR (p.is_division_manager AND p.managed_division_id=pointage_divisions.id)))
 );
GRANT SELECT ON public.pointage_divisions TO authenticated;

CREATE OR REPLACE FUNCTION public.pointage_admin_assign_unit_division(p_unit_id uuid,p_division_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $fn$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND is_admin)
 THEN RAISE EXCEPTION 'Administrateur national requis' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.units WHERE id=p_unit_id AND active AND upper(name)<>'ADMIN')
 THEN RAISE EXCEPTION 'Unité invalide' USING ERRCODE='22023'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.pointage_divisions WHERE id=p_division_id AND active)
 THEN RAISE EXCEPTION 'Division invalide' USING ERRCODE='22023'; END IF;
 -- Empêche le reclassement rétroactif de rapports d'une unité contenant des pointages.
 IF EXISTS(SELECT 1 FROM public.entries WHERE unit_id=p_unit_id)
 AND (SELECT division_id FROM public.units WHERE id=p_unit_id) IS DISTINCT FROM p_division_id
 THEN RAISE EXCEPTION 'Unité avec historique : rattachement de division verrouillé pour préserver les exports';
 END IF;
 UPDATE public.units SET division_id=p_division_id WHERE id=p_unit_id;
END;$fn$;

CREATE OR REPLACE FUNCTION public.pointage_admin_set_division_manager(p_user_id uuid,p_division_id uuid,p_enabled boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE person public.profiles%ROWTYPE;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND is_admin)
 THEN RAISE EXCEPTION 'Administrateur national requis' USING ERRCODE='42501'; END IF;
 SELECT * INTO person FROM public.profiles WHERE id=p_user_id FOR UPDATE;
 IF NOT FOUND OR person.is_admin OR NOT person.active THEN
 RAISE EXCEPTION 'Sélectionne un utilisateur actif non administrateur'; END IF;
 IF p_enabled THEN
  IF p_division_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.pointage_divisions WHERE id=p_division_id AND active)
  THEN RAISE EXCEPTION 'Division invalide'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.units WHERE id=person.unit_id AND division_id=p_division_id)
  THEN RAISE EXCEPTION 'Le responsable doit appartenir à une unité de cette division'; END IF;
  UPDATE public.profiles SET is_division_manager=true,managed_division_id=p_division_id,
   is_unit_manager=false WHERE id=p_user_id;
 ELSE
  UPDATE public.profiles SET is_division_manager=false,managed_division_id=NULL WHERE id=p_user_id;
 END IF;
END;$fn$;

CREATE OR REPLACE FUNCTION public.pointage_division_overview(p_year integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE division_row public.pointage_divisions%ROWTYPE; output jsonb;
BEGIN
 IF p_year<1900 OR p_year>9999 THEN RAISE EXCEPTION 'Année invalide'; END IF;
 SELECT d.* INTO division_row FROM public.pointage_divisions d
 JOIN public.profiles p ON p.managed_division_id=d.id
 WHERE p.id=auth.uid() AND p.active AND p.is_division_manager AND NOT p.is_admin
 AND d.active;
 IF NOT FOUND THEN RAISE EXCEPTION 'Accès Responsable de division requis' USING ERRCODE='42501'; END IF;
 SELECT jsonb_build_object('division',division_row.name,'year',p_year,
 'units',COALESCE(jsonb_agg(jsonb_build_object(
   'id',u.id,'name',u.name,'members',u.members,'entries',u.entries_count,
   'duration_seconds',u.duration_seconds) ORDER BY u.name),'[]'::jsonb))
 INTO output
 FROM (
   SELECT un.id,un.name,
     (SELECT count(*) FROM public.profiles pr WHERE pr.unit_id=un.id AND NOT pr.is_admin) members,
     (SELECT count(*) FROM public.entries e WHERE e.unit_id=un.id AND e.month_key>=p_year::text||'-01'
        AND e.month_key<(p_year+1)::text||'-01') entries_count,
     (SELECT COALESCE(sum(COALESCE(e.duration_seconds,round(e.hours*3600)::bigint)),0)
       FROM public.entries e WHERE e.unit_id=un.id AND e.month_key>=p_year::text||'-01'
         AND e.month_key<(p_year+1)::text||'-01') duration_seconds
   FROM public.units un WHERE un.division_id=division_row.id AND un.active
 ) u;
 RETURN output;
END;$fn$;
REVOKE ALL ON FUNCTION public.pointage_admin_assign_unit_division(uuid,uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.pointage_admin_set_division_manager(uuid,uuid,boolean) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.pointage_division_overview(integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_admin_assign_unit_division(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pointage_admin_set_division_manager(uuid,uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pointage_division_overview(integer) TO authenticated;
