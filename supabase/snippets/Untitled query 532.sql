-- Fix: trg_issue_invoice_on_delivery was generating invoice snapshots
-- WITHOUT currency, fxRate, baseCurrency fields, which caused
-- trg_validate_invoice_snapshot to reject them.

CREATE OR REPLACE FUNCTION public.issue_invoice_on_delivery()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  v_has_invoice boolean;
  v_invoice text;
  v_issued_at timestamptz;
  v_snapshot jsonb;
  v_subtotal numeric;
  v_discount numeric;
  v_delivery_fee numeric;
  v_total numeric;
  v_tax numeric;
  v_currency text;
  v_base_currency text;
  v_fx_rate numeric;
BEGIN
  IF NEW.status = 'delivered' AND (OLD.status IS DISTINCT FROM NEW.status) THEN
    v_has_invoice := (NEW.data ? 'invoiceIssuedAt') AND (NEW.data ? 'invoiceNumber');
    IF NOT coalesce(v_has_invoice, false) THEN
      v_invoice := public.generate_invoice_number();
      v_issued_at := coalesce(
        nullif(NEW.data->>'paidAt', '')::timestamptz,
        nullif(NEW.data->>'deliveredAt', '')::timestamptz,
        now()
      );

      v_subtotal := coalesce(nullif((NEW.data->>'subtotal')::numeric, null), 0);
      v_discount := coalesce(nullif((NEW.data->>'discountAmount')::numeric, null), 0);
      v_delivery_fee := coalesce(nullif((NEW.data->>'deliveryFee')::numeric, null), 0);
      v_tax := coalesce(nullif((NEW.data->>'taxAmount')::numeric, null), 0);
      v_total := coalesce(nullif((NEW.data->>'total')::numeric, null), v_subtotal - v_discount + v_delivery_fee + v_tax);

      -- Derive currency fields from order columns or data, falling back to sensible defaults
      v_currency := coalesce(nullif(NEW.currency, ''), nullif(NEW.data->>'currency', ''), 'SAR');
      v_fx_rate := coalesce(NEW.fx_rate, nullif((NEW.data->>'fxRate')::numeric, null), 1.0);
      v_base_currency := coalesce(
        nullif(NEW.data->'invoiceSnapshot'->>'baseCurrency', ''),
        nullif(NEW.data->>'baseCurrency', ''),
        (select nullif(s.data->>'baseCurrency', '') from public.app_settings s where s.id = 'singleton'),
        'SAR'
      );

      v_snapshot := jsonb_build_object(
        'issuedAt', to_jsonb(v_issued_at),
        'invoiceNumber', to_jsonb(v_invoice),
        'createdAt', to_jsonb(coalesce(nullif(NEW.data->>'createdAt',''), NEW.created_at::text)),
        'orderSource', to_jsonb(coalesce(nullif(NEW.data->>'orderSource',''), 'online')),
        'items', coalesce(NEW.data->'items', '[]'::jsonb),
        'subtotal', to_jsonb(v_subtotal),
        'deliveryFee', to_jsonb(v_delivery_fee),
        'discountAmount', to_jsonb(v_discount),
        'total', to_jsonb(v_total),
        'paymentMethod', to_jsonb(coalesce(nullif(NEW.data->>'paymentMethod',''), 'cash')),
        'customerName', to_jsonb(coalesce(NEW.data->>'customerName', '')),
        'phoneNumber', to_jsonb(coalesce(NEW.data->>'phoneNumber', '')),
        'address', to_jsonb(coalesce(NEW.data->>'address', '')),
        'deliveryZoneId', CASE WHEN NEW.data ? 'deliveryZoneId' THEN to_jsonb(NEW.data->>'deliveryZoneId') ELSE NULL END,
        'currency', to_jsonb(v_currency),
        'fxRate', to_jsonb(v_fx_rate),
        'baseCurrency', to_jsonb(v_base_currency)
      );

      NEW.data := jsonb_set(NEW.data, '{invoiceNumber}', to_jsonb(v_invoice), true);
      NEW.data := jsonb_set(NEW.data, '{invoiceIssuedAt}', to_jsonb(v_issued_at), true);
      NEW.data := jsonb_set(NEW.data, '{invoiceSnapshot}', v_snapshot, true);
      IF NOT (NEW.data ? 'invoicePrintCount') THEN
        NEW.data := jsonb_set(NEW.data, '{invoicePrintCount}', '0'::jsonb, true);
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
