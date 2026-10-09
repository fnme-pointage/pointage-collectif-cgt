-- Permet au formulaire public d'inscription de regrouper les unités par division.
-- Seules les divisions actives sont visibles par les visiteurs non connectés.
CREATE POLICY pointage_divisions_signup_list ON public.pointage_divisions FOR SELECT TO anon USING (active);
