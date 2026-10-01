-- Existing PDFs remain national (unit_id is NULL). No file or document is deleted.
alter table public.pointage_documents add column if not exists unit_id uuid references public.units(id) on delete restrict;
create index if not exists pointage_documents_unit_id_idx on public.pointage_documents(unit_id);
alter policy documents_active_read on public.pointage_documents to authenticated using (
 (select public.pointage_is_admin()) or (
  (select public.current_user_is_active()) and (
   unit_id is null or unit_id=(select p.unit_id from public.profiles p where p.id=(select auth.uid()))
  )
 )
);
alter policy pointage_pdfs_read on storage.objects to authenticated using (
 bucket_id='pointage-documents' and (
  (select public.pointage_is_admin()) or (
   (select public.current_user_is_active()) and exists (
    select 1 from public.pointage_documents d where d.file_path=storage.objects.name
    and (d.unit_id is null or d.unit_id=(select p.unit_id from public.profiles p where p.id=(select auth.uid())))
   )
  )
 )
);
