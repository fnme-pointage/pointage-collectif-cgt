-- Reprendre les controles d'historique du transfert national et borner strictement
-- les deux unites a la division du responsable connecte.
DO $$
DECLARE def text;
BEGIN
 SELECT pg_get_functiondef(oid) INTO def FROM pg_proc WHERE proname='pointage_admin_transfer_user' AND pronamespace='public'::regnamespace;
 def:=replace(def,'pointage_admin_transfer_user(','pointage_division_transfer_user(');
 def:=replace(def,'IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND is_admin)', 'IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id=auth.uid() AND active AND is_division_manager AND NOT is_admin AND managed_division_id IS NOT NULL)');
 def:=replace(def,'Accès administrateur requis','Accès responsable de division requis');
 def:=replace(def,'Un administrateur ne peut pas se transférer','Un responsable ne peut pas se transférer');
 def:=replace(def,'IF oldp.unit_id=p_to_unit_id THEN', 'IF oldp.is_division_manager OR NOT EXISTS (SELECT 1 FROM public.profiles caller JOIN public.units source_unit ON source_unit.id=oldp.unit_id JOIN public.units destination_unit ON destination_unit.id=p_to_unit_id WHERE caller.id=auth.uid() AND source_unit.division_id=caller.managed_division_id AND destination_unit.division_id=caller.managed_division_id) THEN RAISE EXCEPTION ''Transfert hors division ou profil non transférable'' USING ERRCODE=''42501''; END IF; IF oldp.unit_id=p_to_unit_id THEN');
 EXECUTE def;
END $$;
REVOKE ALL ON FUNCTION public.pointage_division_transfer_user(uuid,uuid,date,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pointage_division_transfer_user(uuid,uuid,date,text) TO authenticated;
