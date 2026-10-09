-- Départ vers une autre division : retirer le mandat de la division d'origine.
CREATE OR REPLACE FUNCTION public.pointage_clear_division_on_transfer()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
BEGIN
 IF NEW.is_division_manager AND NOT EXISTS (
  SELECT 1 FROM public.units u WHERE u.id=NEW.unit_id AND u.division_id=NEW.managed_division_id
 ) THEN
  NEW.is_division_manager:=false;
  NEW.managed_division_id:=NULL;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pointage_clear_division_on_transfer ON public.profiles;
CREATE TRIGGER pointage_clear_division_on_transfer
BEFORE UPDATE OF unit_id ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.pointage_clear_division_on_transfer();
