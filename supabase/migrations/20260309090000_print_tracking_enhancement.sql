-- ============================================================================
-- Print Tracking Enhancement
-- Modify mark_accounting_document_printed to return the new print_count
-- so the frontend can display "أصل / ORIGINAL" vs "نسخة / COPY #N"
-- ============================================================================

set app.allow_ledger_ddl = '1';

-- Must drop first because return type changes from void to integer
drop function if exists public.mark_accounting_document_printed(uuid, text);

create or replace function public.mark_accounting_document_printed(
  p_document_id uuid,
  p_template text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc record;
  v_count integer;
  v_user_name text;
begin
  if not public.has_admin_permission('accounting.view') then
    raise exception 'not allowed';
  end if;

  update public.accounting_documents
  set print_count = coalesce(print_count, 0) + 1,
      last_printed_at = now(),
      last_printed_template = nullif(btrim(coalesce(p_template,'')),'' )
  where id = p_document_id
  returning print_count into v_count;

  if v_count is null then
    return 0;
  end if;

  -- Resolve the user's display name for richer audit
  begin
    select coalesce(au.full_name, au.username, au.email, auth.uid()::text)
    into v_user_name
    from public.admin_users au
    where au.auth_user_id = auth.uid();
  exception when others then
    v_user_name := coalesce(auth.uid()::text, 'unknown');
  end;

  select * into v_doc from public.accounting_documents where id = p_document_id;
  if found then
    insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata)
    values (
      'print',
      'documents',
      concat('Printed document ', coalesce(v_doc.document_number, v_doc.id::text), ' (copy #', v_count, ')'),
      auth.uid(),
      now(),
      jsonb_build_object(
        'documentId', v_doc.id,
        'documentType', v_doc.document_type,
        'documentNumber', v_doc.document_number,
        'sourceTable', v_doc.source_table,
        'sourceId', v_doc.source_id,
        'template', nullif(btrim(coalesce(p_template,'')),'' ),
        'printNumber', v_count,
        'printedByName', v_user_name
      )
    );
  end if;

  return v_count;
end;
$$;

revoke all on function public.mark_accounting_document_printed(uuid, text) from public;
revoke execute on function public.mark_accounting_document_printed(uuid, text) from anon;
grant execute on function public.mark_accounting_document_printed(uuid, text) to authenticated;

notify pgrst, 'reload schema';
