set app.allow_ledger_ddl = '1';

do $$
begin
  begin
    alter table public.accounting_documents drop constraint accounting_documents_document_type_check;
  exception when others then
    null;
  end;

  alter table public.accounting_documents
    add constraint accounting_documents_document_type_check
    check (document_type in ('po','grn','invoice','payment','receipt','journal','writeoff','manual','movement'));
end $$;

notify pgrst, 'reload schema';

