set app.allow_ledger_ddl = '1';

do $$
declare
  v_con record;
begin
  if to_regclass('public.employee_contracts') is not null then
    for v_con in
      select c.conname
      from pg_constraint c
      join pg_class t on t.oid = c.conrelid
      join pg_namespace n on n.oid = t.relnamespace
      where n.nspname = 'public'
        and t.relname = 'employee_contracts'
        and c.contype = 'c'
        and pg_get_constraintdef(c.oid) ilike '%status%'
    loop
      execute format('alter table public.employee_contracts drop constraint if exists %I', v_con.conname);
    end loop;
    if not exists (
      select 1 from pg_constraint
      where conname = 'employee_contracts_status_workflow_ck'
        and conrelid = 'public.employee_contracts'::regclass
    ) then
      alter table public.employee_contracts
        add constraint employee_contracts_status_workflow_ck
        check (status in ('draft','under_review','approved','signed','active','expired','terminated','archived'));
    end if;
    begin alter table public.employee_contracts add column submitted_at timestamptz; exception when duplicate_column then null; end;
    begin alter table public.employee_contracts add column submitted_by uuid references auth.users(id) on delete set null; exception when duplicate_column then null; end;
    begin alter table public.employee_contracts add column reviewed_at timestamptz; exception when duplicate_column then null; end;
    begin alter table public.employee_contracts add column reviewed_by uuid references auth.users(id) on delete set null; exception when duplicate_column then null; end;
    begin alter table public.employee_contracts add column approved_at timestamptz; exception when duplicate_column then null; end;
    begin alter table public.employee_contracts add column approved_by uuid references auth.users(id) on delete set null; exception when duplicate_column then null; end;
    begin alter table public.employee_contracts add column signed_at timestamptz; exception when duplicate_column then null; end;
    begin alter table public.employee_contracts add column signed_by uuid references auth.users(id) on delete set null; exception when duplicate_column then null; end;
    begin alter table public.employee_contracts add column signed_signature text; exception when duplicate_column then null; end;
    begin alter table public.employee_contracts add column archived_at timestamptz; exception when duplicate_column then null; end;
    begin alter table public.employee_contracts add column archived_by uuid references auth.users(id) on delete set null; exception when duplicate_column then null; end;
  end if;

  if to_regclass('public.employee_guarantees') is not null then
    for v_con in
      select c.conname
      from pg_constraint c
      join pg_class t on t.oid = c.conrelid
      join pg_namespace n on n.oid = t.relnamespace
      where n.nspname = 'public'
        and t.relname = 'employee_guarantees'
        and c.contype = 'c'
        and pg_get_constraintdef(c.oid) ilike '%status%'
    loop
      execute format('alter table public.employee_guarantees drop constraint if exists %I', v_con.conname);
    end loop;
    if not exists (
      select 1 from pg_constraint
      where conname = 'employee_guarantees_status_workflow_ck'
        and conrelid = 'public.employee_guarantees'::regclass
    ) then
      alter table public.employee_guarantees
        add constraint employee_guarantees_status_workflow_ck
        check (status in ('draft','under_review','approved','signed','active','expired','released','archived'));
    end if;
    begin alter table public.employee_guarantees add column submitted_at timestamptz; exception when duplicate_column then null; end;
    begin alter table public.employee_guarantees add column submitted_by uuid references auth.users(id) on delete set null; exception when duplicate_column then null; end;
    begin alter table public.employee_guarantees add column reviewed_at timestamptz; exception when duplicate_column then null; end;
    begin alter table public.employee_guarantees add column reviewed_by uuid references auth.users(id) on delete set null; exception when duplicate_column then null; end;
    begin alter table public.employee_guarantees add column approved_at timestamptz; exception when duplicate_column then null; end;
    begin alter table public.employee_guarantees add column approved_by uuid references auth.users(id) on delete set null; exception when duplicate_column then null; end;
    begin alter table public.employee_guarantees add column signed_at timestamptz; exception when duplicate_column then null; end;
    begin alter table public.employee_guarantees add column signed_by uuid references auth.users(id) on delete set null; exception when duplicate_column then null; end;
    begin alter table public.employee_guarantees add column signed_signature text; exception when duplicate_column then null; end;
    begin alter table public.employee_guarantees add column archived_at timestamptz; exception when duplicate_column then null; end;
    begin alter table public.employee_guarantees add column archived_by uuid references auth.users(id) on delete set null; exception when duplicate_column then null; end;
  end if;
end $$;

create table if not exists public.hr_document_approvals (
  id uuid primary key default gen_random_uuid(),
  document_type text not null check (document_type in ('contract','guarantee')),
  document_id uuid not null,
  action text not null,
  from_status text,
  to_status text,
  comment text,
  signature_name text,
  metadata jsonb not null default '{}'::jsonb,
  performed_by uuid references auth.users(id) on delete set null,
  performed_at timestamptz not null default now()
);

create index if not exists idx_hr_document_approvals_doc on public.hr_document_approvals(document_type, document_id, performed_at desc);
create index if not exists idx_hr_document_approvals_actor on public.hr_document_approvals(performed_by, performed_at desc);

alter table public.hr_document_approvals enable row level security;

drop policy if exists hr_document_approvals_select on public.hr_document_approvals;
create policy hr_document_approvals_select
on public.hr_document_approvals
for select
using (
  public.has_admin_permission('hr.contracts.view')
  or public.has_admin_permission('expenses.manage')
  or public.has_admin_permission('accounting.view')
  or public.is_admin()
);

drop policy if exists hr_document_approvals_write on public.hr_document_approvals;
create policy hr_document_approvals_write
on public.hr_document_approvals
for insert
with check (
  public.has_admin_permission('hr.contracts.manage')
  or public.has_admin_permission('hr.contracts.approve')
  or public.has_admin_permission('accounting.approve')
  or public.is_admin()
);

create or replace function public.hr_transition_employee_document(
  p_document_type text,
  p_document_id uuid,
  p_action text,
  p_comment text default null,
  p_signature_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type text := lower(trim(coalesce(p_document_type, '')));
  v_action text := lower(trim(coalesce(p_action, '')));
  v_current text;
  v_next text;
  v_comment text := nullif(trim(coalesce(p_comment, '')), '');
  v_signature text := nullif(trim(coalesce(p_signature_name, '')), '');
  v_can_manage boolean := public.has_admin_permission('hr.contracts.manage') or public.has_admin_permission('expenses.manage') or public.has_admin_permission('accounting.manage') or public.is_admin();
  v_can_approve boolean := public.has_admin_permission('hr.contracts.approve') or public.has_admin_permission('accounting.approve') or public.is_owner() or public.is_admin();
begin
  if p_document_id is null then
    raise exception 'document_id is required';
  end if;
  if v_type not in ('contract', 'guarantee') then
    raise exception 'invalid document type';
  end if;
  if v_action = '' then
    raise exception 'action is required';
  end if;

  if v_type = 'contract' then
    select status into v_current from public.employee_contracts where id = p_document_id for update;
    if not found then raise exception 'contract not found'; end if;
  else
    select status into v_current from public.employee_guarantees where id = p_document_id for update;
    if not found then raise exception 'guarantee not found'; end if;
  end if;

  if v_action = 'submit_review' then
    if not v_can_manage then raise exception 'not allowed'; end if;
    if v_current not in ('draft') then raise exception 'invalid transition from %', v_current; end if;
    v_next := 'under_review';
  elsif v_action = 'return_draft' then
    if not v_can_approve then raise exception 'not allowed'; end if;
    if v_current not in ('under_review','approved') then raise exception 'invalid transition from %', v_current; end if;
    v_next := 'draft';
  elsif v_action = 'approve' then
    if not v_can_approve then raise exception 'not allowed'; end if;
    if v_current <> 'under_review' then raise exception 'invalid transition from %', v_current; end if;
    v_next := 'approved';
  elsif v_action = 'sign' then
    if not v_can_approve then raise exception 'not allowed'; end if;
    if v_current <> 'approved' then raise exception 'invalid transition from %', v_current; end if;
    if v_signature is null then raise exception 'signature name is required'; end if;
    v_next := 'signed';
  elsif v_action = 'activate' then
    if not v_can_manage then raise exception 'not allowed'; end if;
    if v_current not in ('signed') then raise exception 'invalid transition from %', v_current; end if;
    v_next := 'active';
  elsif v_action = 'archive' then
    if not v_can_manage then raise exception 'not allowed'; end if;
    if v_current not in ('signed','active','expired','terminated','released') then raise exception 'invalid transition from %', v_current; end if;
    v_next := 'archived';
  elsif v_action = 'terminate' then
    if not v_can_manage then raise exception 'not allowed'; end if;
    if v_type <> 'contract' then raise exception 'terminate is for contract only'; end if;
    if v_current not in ('active','signed') then raise exception 'invalid transition from %', v_current; end if;
    v_next := 'terminated';
  elsif v_action = 'release' then
    if not v_can_manage then raise exception 'not allowed'; end if;
    if v_type <> 'guarantee' then raise exception 'release is for guarantee only'; end if;
    if v_current not in ('active','signed') then raise exception 'invalid transition from %', v_current; end if;
    v_next := 'released';
  elsif v_action = 'expire' then
    if not v_can_manage then raise exception 'not allowed'; end if;
    if v_current not in ('active','signed') then raise exception 'invalid transition from %', v_current; end if;
    v_next := 'expired';
  else
    raise exception 'unsupported action';
  end if;

  if v_type = 'contract' then
    update public.employee_contracts
    set status = v_next,
        submitted_at = case when v_next = 'under_review' then now() else submitted_at end,
        submitted_by = case when v_next = 'under_review' then auth.uid() else submitted_by end,
        reviewed_at = case when v_action in ('return_draft','approve') then now() else reviewed_at end,
        reviewed_by = case when v_action in ('return_draft','approve') then auth.uid() else reviewed_by end,
        approved_at = case when v_action = 'approve' then now() else approved_at end,
        approved_by = case when v_action = 'approve' then auth.uid() else approved_by end,
        signed_at = case when v_action = 'sign' then now() else signed_at end,
        signed_by = case when v_action = 'sign' then auth.uid() else signed_by end,
        signed_signature = case when v_action = 'sign' then v_signature else signed_signature end,
        archived_at = case when v_action = 'archive' then now() else archived_at end,
        archived_by = case when v_action = 'archive' then auth.uid() else archived_by end,
        updated_at = now(),
        updated_by = auth.uid()
    where id = p_document_id;
  else
    update public.employee_guarantees
    set status = v_next,
        submitted_at = case when v_next = 'under_review' then now() else submitted_at end,
        submitted_by = case when v_next = 'under_review' then auth.uid() else submitted_by end,
        reviewed_at = case when v_action in ('return_draft','approve') then now() else reviewed_at end,
        reviewed_by = case when v_action in ('return_draft','approve') then auth.uid() else reviewed_by end,
        approved_at = case when v_action = 'approve' then now() else approved_at end,
        approved_by = case when v_action = 'approve' then auth.uid() else approved_by end,
        signed_at = case when v_action = 'sign' then now() else signed_at end,
        signed_by = case when v_action = 'sign' then auth.uid() else signed_by end,
        signed_signature = case when v_action = 'sign' then v_signature else signed_signature end,
        archived_at = case when v_action = 'archive' then now() else archived_at end,
        archived_by = case when v_action = 'archive' then auth.uid() else archived_by end,
        updated_at = now(),
        updated_by = auth.uid()
    where id = p_document_id;
  end if;

  insert into public.hr_document_approvals(
    document_type, document_id, action, from_status, to_status, comment, signature_name, metadata, performed_by
  ) values (
    v_type, p_document_id, v_action, v_current, v_next, v_comment, v_signature,
    jsonb_build_object('action', v_action, 'comment', coalesce(v_comment, ''), 'signature', coalesce(v_signature, '')),
    auth.uid()
  );

  insert into public.system_audit_logs(
    action, module, details, performed_by, performed_at, metadata, risk_level, reason_code
  ) values (
    'hr.workflow.transition',
    'hr',
    concat(upper(v_type), ' ', right(p_document_id::text, 8), ' ', v_current, ' -> ', v_next),
    auth.uid(),
    now(),
    jsonb_build_object(
      'documentType', v_type,
      'documentId', p_document_id::text,
      'action', v_action,
      'from', v_current,
      'to', v_next,
      'comment', coalesce(v_comment, ''),
      'signature', coalesce(v_signature, '')
    ),
    'MEDIUM',
    'HR_WORKFLOW'
  );

  return jsonb_build_object(
    'success', true,
    'documentType', v_type,
    'documentId', p_document_id::text,
    'action', v_action,
    'fromStatus', v_current,
    'toStatus', v_next
  );
end;
$$;

revoke all on function public.hr_transition_employee_document(text, uuid, text, text, text) from public;
grant execute on function public.hr_transition_employee_document(text, uuid, text, text, text) to authenticated;

notify pgrst, 'reload schema';
