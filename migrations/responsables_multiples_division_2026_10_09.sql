-- Autoriser plusieurs responsables de division sans changer leurs autres habilitations.
DROP INDEX IF EXISTS public.pointage_division_one_manager;
CREATE INDEX IF NOT EXISTS pointage_division_managers_lookup
  ON public.profiles(managed_division_id) WHERE is_division_manager;
