set app.allow_ledger_ddl = '1';

create or replace function public.replace_asset_component(
  p_component_id uuid,
  p_new_name_ar text,
  p_new_cost numeric,
  p_new_useful_life_months int,
  p_replacement_date date default current_date,
  p_payment_method text default 'cash',
  p_new_salvage_value numeric default 0,
  p_new_depreciation_method text default 'straight_line',
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old record;
  v_asset record;
  v_cat record;
  v_new_component_id uuid;
  v_old_nbv numeric;
  v_entry_id uuid;
  v_asset_account uuid;
  v_accum_account uuid;
  v_impair_allowance uuid;
  v_gain_loss_account uuid;
  v_credit_account uuid;
begin
  perform public._require_staff('replace_asset_component');
  if not (auth.role() = 'service_role' or public.is_owner_or_manager()) then
    raise exception 'not authorized';
  end if;

  if p_component_id is null then
    raise exception 'component id is required';
  end if;
  if p_new_name_ar is null or btrim(p_new_name_ar) = '' then
    raise exception 'new component name is required';
  end if;
  if p_new_cost is null or p_new_cost <= 0 then
    raise exception 'new component cost must be positive';
  end if;
  if p_new_useful_life_months is null or p_new_useful_life_months <= 0 then
    raise exception 'new component useful life must be positive';
  end if;
  if p_replacement_date is null then
    raise exception 'replacement date is required';
  end if;
  if public.is_in_closed_period((p_replacement_date)::timestamptz) then
    raise exception 'Cannot replace component in a closed accounting period.';
  end if;

  select * into v_old
  from public.fixed_asset_components
  where id = p_component_id
  for update;
  if not found then
    raise exception 'component not found';
  end if;
  if v_old.status <> 'active' then
    raise exception 'component is not active';
  end if;

  select * into v_asset
  from public.fixed_assets
  where id = v_old.asset_id
  for update;
  if not found then
    raise exception 'parent asset not found';
  end if;
  if v_asset.status = 'disposed' then
    raise exception 'parent asset is disposed';
  end if;

  select * into v_cat
  from public.fixed_asset_categories
  where id = v_asset.category_id;

  v_old_nbv := greatest(
    coalesce(v_old.cost, 0)
    - coalesce(v_old.accumulated_depreciation, 0)
    - coalesce(v_old.impairment_accumulated, 0),
    0
  );

  v_asset_account := public.get_account_id_by_code(coalesce(v_cat.account_code, '1500'));
  if v_asset_account is null then
    v_asset_account := public.get_account_id_by_code('1500');
  end if;
  v_accum_account := public.get_account_id_by_code('1550');
  v_impair_allowance := public.get_account_id_by_code('1560');
  v_gain_loss_account := public.get_account_id_by_code('4030');
  if p_payment_method in ('credit', 'ap') then
    v_credit_account := public.get_account_id_by_code('2010');
  else
    v_credit_account := public.get_account_id_by_code('1010');
  end if;
  if v_asset_account is null or v_accum_account is null or v_gain_loss_account is null or v_credit_account is null then
    raise exception 'required accounts are missing';
  end if;

  insert into public.journal_entries(entry_date, memo, source_table, source_id, source_event, created_by, status)
  values (
    p_replacement_date,
    concat('استبدال مكوّن أصل: ', v_old.name_ar, ' ← ', btrim(p_new_name_ar)),
    'fixed_asset_components',
    p_component_id::text || ':replacement',
    'component_replacement',
    auth.uid(),
    'posted'
  )
  returning id into v_entry_id;

  if coalesce(v_old.accumulated_depreciation, 0) > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (
      v_entry_id, v_accum_account, public._money_round(v_old.accumulated_depreciation), 0, concat('إلغاء مجمع إهلاك المكوّن ', v_old.component_code)
    );
  end if;

  if coalesce(v_old.impairment_accumulated, 0) > 0 and v_impair_allowance is not null then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (
      v_entry_id, v_impair_allowance, public._money_round(v_old.impairment_accumulated), 0, concat('إلغاء مخصص انخفاض قيمة المكوّن ', v_old.component_code)
    );
  end if;

  if v_old_nbv > 0 then
    insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
    values (
      v_entry_id, v_gain_loss_account, public._money_round(v_old_nbv), 0, concat('خسارة استبدال المكوّن ', v_old.component_code)
    );
  end if;

  insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
  values (
    v_entry_id, v_asset_account, 0, public._money_round(v_old.cost), concat('إلغاء تكلفة المكوّن ', v_old.component_code)
  );

  insert into public.journal_lines(journal_entry_id, account_id, debit, credit, line_memo)
  values
    (v_entry_id, v_asset_account, public._money_round(p_new_cost), 0, concat('إضافة المكوّن الجديد ', btrim(p_new_name_ar))),
    (v_entry_id, v_credit_account, 0, public._money_round(p_new_cost), case when p_payment_method in ('credit', 'ap') then 'ذمم دائنة' else 'نقداً' end);

  perform public.check_journal_entry_balance(v_entry_id);

  update public.fixed_asset_components
  set status = 'replaced',
      updated_at = now(),
      notes = trim(concat(coalesce(notes, ''), case when coalesce(notes, '') = '' then '' else ' | ' end, 'replaced on ', p_replacement_date::text, case when coalesce(p_reason, '') = '' then '' else concat(' - ', p_reason) end))
  where id = p_component_id;

  v_new_component_id := gen_random_uuid();
  insert into public.fixed_asset_components(
    id, asset_id, component_code, name_ar, acquisition_date, cost, salvage_value,
    useful_life_months, depreciation_method, notes, created_by
  )
  values (
    v_new_component_id,
    v_old.asset_id,
    public._next_asset_component_code(),
    btrim(p_new_name_ar),
    p_replacement_date,
    p_new_cost,
    coalesce(p_new_salvage_value, 0),
    p_new_useful_life_months,
    case when lower(coalesce(p_new_depreciation_method, 'straight_line')) in ('straight_line', 'declining_balance') then lower(p_new_depreciation_method) else 'straight_line' end,
    nullif(trim(coalesce(p_reason, '')), ''),
    auth.uid()
  );

  insert into public.system_audit_logs(action, module, details, performed_by, performed_at, metadata, risk_level, reason_code)
  values (
    'fixed_assets.component_replace',
    'fixed_assets',
    v_old.asset_id::text,
    auth.uid(),
    now(),
    jsonb_build_object(
      'assetId', v_old.asset_id,
      'oldComponentId', p_component_id,
      'newComponentId', v_new_component_id,
      'oldComponentCode', v_old.component_code,
      'newName', p_new_name_ar,
      'newCost', p_new_cost,
      'replacementDate', p_replacement_date,
      'paymentMethod', p_payment_method,
      'reason', nullif(trim(coalesce(p_reason, '')), '')
    ),
    'HIGH',
    'ASSET_COMPONENT_REPLACE'
  );

  return jsonb_build_object(
    'success', true,
    'assetId', v_old.asset_id::text,
    'oldComponentId', p_component_id::text,
    'newComponentId', v_new_component_id::text
  );
end;
$$;

revoke all on function public.replace_asset_component(uuid, text, numeric, int, date, text, numeric, text, text) from public;
grant execute on function public.replace_asset_component(uuid, text, numeric, int, date, text, numeric, text, text) to authenticated;

notify pgrst, 'reload schema';
