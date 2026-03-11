-- ═══════════════════════════════════════════════════════════════
-- FIX: Correct inflated price in order 158e2589
-- 
-- Order was created during the FX bug period (Feb 28 - Mar 9)
-- Item price was set to 2900 SAR (raw YER cost without conversion)
-- Correct price: 7.23 SAR (the current menu_items selling price)
--
-- Also fixes: _basePrice, _fefoMinPrice, _fefoUnitCost, subtotal, total
-- ═══════════════════════════════════════════════════════════════

set app.allow_ledger_ddl = '1';

do $$
declare
  v_order_id constant uuid := '158e2589-d1d7-4db9-beac-154dcfc3a98c';
  v_item_id  constant text := 'efa91e13-9cb2-4fb1-b3f0-4f711c22e59a';
  v_correct_price constant numeric := 7.23;
  v_data jsonb;
  v_items jsonb;
  v_inv_items jsonb;
  v_item jsonb;
  v_new_items jsonb;
  v_new_inv_items jsonb;
  v_i int;
begin
  raise notice 'Fixing order % inflated price (2900 → %)', left(v_order_id::text, 8), v_correct_price;

  select data into v_data from public.orders where id = v_order_id;
  if v_data is null then
    raise notice 'Order not found, skipping';
    return;
  end if;

  -- Fix items array
  v_items := v_data->'items';
  v_new_items := '[]'::jsonb;
  if jsonb_typeof(v_items) = 'array' then
    for v_i in 0..(jsonb_array_length(v_items) - 1) loop
      v_item := v_items->v_i;
      if (v_item->>'id' = v_item_id or v_item->>'itemId' = v_item_id) then
        v_item := jsonb_set(v_item, '{price}', to_jsonb(v_correct_price));
        v_item := jsonb_set(v_item, '{_basePrice}', to_jsonb(v_correct_price));
        -- Fix FEFO fields if they exist
        if v_item ? '_fefoMinPrice' then
          v_item := jsonb_set(v_item, '{_fefoMinPrice}', to_jsonb(v_correct_price));
        end if;
        if v_item ? '_fefoUnitCost' then
          v_item := jsonb_set(v_item, '{_fefoUnitCost}', to_jsonb(v_correct_price));
        end if;
        raise notice 'Fixed items[%] price: 2900 → %', v_i, v_correct_price;
      end if;
      v_new_items := v_new_items || jsonb_build_array(v_item);
    end loop;
    v_data := jsonb_set(v_data, '{items}', v_new_items);
  end if;

  -- Fix invoiceSnapshot.items array
  v_inv_items := v_data->'invoiceSnapshot'->'items';
  v_new_inv_items := '[]'::jsonb;
  if jsonb_typeof(v_inv_items) = 'array' then
    for v_i in 0..(jsonb_array_length(v_inv_items) - 1) loop
      v_item := v_inv_items->v_i;
      if (v_item->>'id' = v_item_id or v_item->>'itemId' = v_item_id) then
        v_item := jsonb_set(v_item, '{price}', to_jsonb(v_correct_price));
        v_item := jsonb_set(v_item, '{_basePrice}', to_jsonb(v_correct_price));
        if v_item ? '_fefoMinPrice' then
          v_item := jsonb_set(v_item, '{_fefoMinPrice}', to_jsonb(v_correct_price));
        end if;
        if v_item ? '_fefoUnitCost' then
          v_item := jsonb_set(v_item, '{_fefoUnitCost}', to_jsonb(v_correct_price));
        end if;
        raise notice 'Fixed invoiceSnapshot.items[%] price: 2900 → %', v_i, v_correct_price;
      end if;
      v_new_inv_items := v_new_inv_items || jsonb_build_array(v_item);
    end loop;
    v_data := jsonb_set(v_data, '{invoiceSnapshot,items}', v_new_inv_items);
  end if;

  -- Fix totals (single item order, so total = price × quantity = 7.23 × 1)
  v_data := jsonb_set(v_data, '{subtotal}', to_jsonb(v_correct_price));
  v_data := jsonb_set(v_data, '{total}', to_jsonb(v_correct_price));

  -- Also fix invoiceSnapshot totals if they exist
  if v_data->'invoiceSnapshot' ? 'subtotal' then
    v_data := jsonb_set(v_data, '{invoiceSnapshot,subtotal}', to_jsonb(v_correct_price));
  end if;
  if v_data->'invoiceSnapshot' ? 'total' then
    v_data := jsonb_set(v_data, '{invoiceSnapshot,total}', to_jsonb(v_correct_price));
  end if;

  -- Update the order (disable immutability trigger)
  alter table public.orders disable trigger user;

  update public.orders
  set data = v_data, updated_at = now()
  where id = v_order_id;

  alter table public.orders enable trigger user;

  raise notice 'Order % updated: total=%, subtotal=%',
    left(v_order_id::text, 8), v_correct_price, v_correct_price;

  -- Also fix corresponding journal entries for this order's sale
  -- The sale journal entries should reflect the correct revenue
  alter table public.journal_lines disable trigger user;

  update public.journal_lines jl
  set debit = case when jl.debit > 0 then v_correct_price else 0 end,
      credit = case when jl.credit > 0 then v_correct_price else 0 end
  from public.journal_entries je
  where jl.journal_entry_id = je.id
    and je.source_table = 'orders'
    and je.source_id = v_order_id::text
    and (jl.debit = 2900 or jl.credit = 2900);

  alter table public.journal_lines enable trigger user;

  raise notice 'Order % fix complete', left(v_order_id::text, 8);
end $$;

notify pgrst, 'reload schema';
