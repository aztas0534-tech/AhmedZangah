-- ============================================================================
-- Generic Document Print Tracking
-- For documents without accounting_documents records (returns, POs, GRNs, etc.)
-- ============================================================================

-- Table to track print counts for any document type
create table if not exists public.document_print_counts (
  source_table text not null,
  source_id text not null,
  print_count integer not null default 0,
  last_printed_at timestamptz,
  last_printed_by uuid,
  last_template text,
  primary key (source_table, source_id)
);

alter table public.document_print_counts enable row level security;
drop policy if exists dpc_authenticated on public.document_print_counts;
create policy dpc_authenticated on public.document_print_counts
  for all using (auth.role() = 'authenticated')
  with check (auth.role() = 'authenticated');

-- RPC: track any document print and return the new count
create or replace function public.track_document_print(
  p_source_table text,
  p_source_id text,
  p_template text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.document_print_counts (source_table, source_id, print_count, last_printed_at, last_printed_by, last_template)
  values (p_source_table, p_source_id, 1, now(), auth.uid(), nullif(btrim(coalesce(p_template,'')), ''))
  on conflict (source_table, source_id) do update
  set print_count = document_print_counts.print_count + 1,
      last_printed_at = now(),
      last_printed_by = auth.uid(),
      last_template = nullif(btrim(coalesce(p_template,'')), '')
  returning print_count into v_count;

  return coalesce(v_count, 1);
end;
$$;

revoke all on function public.track_document_print(text, text, text) from public;
revoke execute on function public.track_document_print(text, text, text) from anon;
grant execute on function public.track_document_print(text, text, text) to authenticated;

notify pgrst, 'reload schema';
