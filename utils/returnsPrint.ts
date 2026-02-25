import { createElement } from 'react';
import { renderToString } from 'react-dom/server';
import { getSupabaseClient } from '../supabase';
import { printContent } from './printUtils';
import PrintableSalesReturnNote, { PrintableSalesReturnNoteData } from '../components/admin/returns/PrintableSalesReturnNote';
import PrintablePurchaseReturnNote, { PrintablePurchaseReturnNoteData } from '../components/admin/returns/PrintablePurchaseReturnNote';
import { DocumentAuditInfo } from './documentStandards';

type Brand = {
  name?: string;
  address?: string;
  contactNumber?: string;
  logoUrl?: string;
  branchName?: string;
  branchCode?: string;
};

const roundMoney = (amount: number, currency: string) => {
  const cur = String(currency || '').trim().toUpperCase() || 'YER';
  const n = Number(amount || 0);
  const digits = cur === 'YER' ? 0 : 2;
  const factor = Math.pow(10, digits);
  return Math.round(n * factor) / factor;
};

export const printSalesReturnById = async (returnId: string, brand?: Brand, audit?: DocumentAuditInfo | null) => {
  const supabase = getSupabaseClient();
  if (!supabase) throw new Error('Supabase غير مهيأ.');
  const rid = String(returnId || '').trim();
  if (!rid) throw new Error('معرف المرتجع غير صالح.');

  let ret: any = null;
  try {
    const res = await supabase
      .from('sales_returns')
      .select('id,order_id,return_date,reason,refund_method,total_refund_amount,items,status,created_at')
      .eq('id', rid)
      .maybeSingle();
    if (res.error) throw res.error;
    ret = res.data;
  } catch (e) {
    const res2 = await supabase
      .from('sales_returns')
      .select('id,order_id,return_date,reason,refund_method,total_refund_amount,status,created_at')
      .eq('id', rid)
      .maybeSingle();
    if (res2.error) throw res2.error;
    ret = res2.data;
  }
  if (!ret) throw new Error('المرتجع غير موجود.');

  const orderId = String((ret as any).order_id || '').trim();
  if (!orderId) throw new Error('الطلب غير صالح.');

  let order: any = null;
  try {
    const res = await supabase
      .from('orders')
      .select('id,invoice_number,customer_name,phone_number,currency,subtotal,discount,tax_amount,data')
      .eq('id', orderId)
      .maybeSingle();
    if (res.error) throw res.error;
    order = res.data;
  } catch (e) {
    const res2 = await supabase
      .from('orders')
      .select('id,invoice_number,currency,data')
      .eq('id', orderId)
      .maybeSingle();
    if (res2.error) throw res2.error;
    order = res2.data;
  }

  const currency = String((order as any)?.currency || (order as any)?.data?.currency || '').trim().toUpperCase() || 'YER';
  const subtotal = Number((order as any)?.data?.subtotal ?? (order as any)?.subtotal ?? 0) || 0;
  const discount = Number((order as any)?.data?.discountAmount ?? (order as any)?.discount ?? 0) || 0;
  const netSubtotal = Math.max(0, subtotal - discount);
  const tax = Number((order as any)?.data?.taxAmount ?? (order as any)?.tax_amount ?? 0) || 0;

  const returnSubtotal = roundMoney(Number((ret as any)?.total_refund_amount || 0), currency);
  const taxRefund = roundMoney(netSubtotal > 0 ? Math.min(tax, (returnSubtotal / netSubtotal) * tax) : 0, currency);
  const totalRefund = roundMoney(returnSubtotal + taxRefund, currency);

  const invoiceNumber = (() => {
    const v = String((order as any)?.invoice_number || (order as any)?.data?.invoiceNumber || (order as any)?.data?.invoice_number || '').trim();
    return v || null;
  })();

  const items = Array.isArray((ret as any)?.items) ? (ret as any).items : [];
  const data: PrintableSalesReturnNoteData = {
    returnId: String((ret as any).id),
    orderId,
    invoiceNumber,
    returnDate: String((ret as any)?.return_date || (ret as any)?.created_at || new Date().toISOString()),
    status: String((ret as any)?.status || '').trim() || null,
    customerName: String((order as any)?.customer_name || (order as any)?.data?.customerName || '').trim() || null,
    customerPhone: String((order as any)?.phone_number || (order as any)?.data?.phoneNumber || '').trim() || null,
    reason: String((ret as any)?.reason || '').trim() || null,
    refundMethod: String((ret as any)?.refund_method || '').trim() || null,
    currency,
    returnSubtotal,
    taxRefund,
    totalRefund,
    items: items.map((it: any) => ({
      itemId: String(it?.itemId || it?.item_id || ''),
      itemName: String(it?.itemName || it?.item_name || ''),
      quantityBase: Number(it?.quantityBase ?? it?.qtyBase ?? it?.qty_base ?? it?.quantity ?? 0) || 0,
      salesUnitQty: it?.salesUnitQty != null ? (Number(it.salesUnitQty) || 0) : null,
      uomCode: it?.uomCode ? String(it.uomCode) : null,
      unitPrice: Number(it?.unitPrice || it?.unit_price || 0) || 0,
      total: Number(it?.total || 0) || 0,
      reason: it?.reason ? String(it.reason) : null,
    })),
  };

  const html = renderToString(createElement(PrintableSalesReturnNote as any, { data, brand, audit }));
  printContent(html, `مرتجع مبيعات #${String(data.returnId).slice(-8)}`);
  try {
    await supabase.from('system_audit_logs').insert({
      action: 'print',
      module: 'documents',
      details: `Printed Sales Return ${String(data.returnId).slice(-8)}`,
      metadata: {
        docType: 'sales_return_note',
        docNumber: String(data.returnId).slice(-8),
        status: data.status,
        sourceTable: 'sales_returns',
        sourceId: data.returnId,
        template: 'PrintableSalesReturnNote',
        orderId: data.orderId,
        invoiceNumber: data.invoiceNumber,
      },
    } as any);
  } catch {
  }
};

export const printPurchaseReturnById = async (returnId: string, brand?: Brand, baseCurrencyOverride?: string, audit?: DocumentAuditInfo | null) => {
  const supabase = getSupabaseClient();
  if (!supabase) throw new Error('Supabase غير مهيأ.');
  const rid = String(returnId || '').trim();
  if (!rid) throw new Error('معرف المرتجع غير صالح.');

  const { data: ret, error: rErr } = await supabase
    .from('purchase_returns')
    .select('id,purchase_order_id,returned_at,reason,created_at')
    .eq('id', rid)
    .maybeSingle();
  if (rErr) throw rErr;
  if (!ret) throw new Error('المرتجع غير موجود.');

  const poId = String((ret as any).purchase_order_id || '').trim();
  if (!poId) throw new Error('أمر الشراء غير صالح.');

  const { data: po, error: poErr } = await supabase
    .from('purchase_orders')
    .select('id,currency,fx_rate,reference_number,supplier_id,suppliers(name)')
    .eq('id', poId)
    .maybeSingle();
  if (poErr) throw poErr;

  const baseCurrency = String(baseCurrencyOverride || '').trim().toUpperCase() || 'YER';
  const currency = String((po as any)?.currency || baseCurrency).trim().toUpperCase() || baseCurrency;
  const fxRate = Number((po as any)?.fx_rate || 1) || 1;
  const safeFx = fxRate > 0 ? fxRate : 1;

  let retItems: any[] = [];
  try {
    const { data, error: riErr } = await supabase
      .from('purchase_return_items')
      .select('item_id,quantity,menu_items(name)')
      .eq('return_id', rid)
      .order('created_at', { ascending: true });
    if (riErr) throw riErr;
    retItems = Array.isArray(data) ? data : [];
  } catch {
    try {
      const { data, error: riErr2 } = await supabase
        .from('purchase_return_items')
        .select('item_id,quantity,menu_items(name)')
        .eq('purchase_return_id', rid)
        .order('created_at', { ascending: true });
      if (riErr2) throw riErr2;
      retItems = Array.isArray(data) ? data : [];
    } catch {
      retItems = [];
    }
  }

  const { data: mv, error: mvErr } = await supabase
    .from('inventory_movements')
    .select('total_cost')
    .eq('reference_table', 'purchase_returns')
    .eq('reference_id', rid)
    .eq('movement_type', 'return_out');
  if (mvErr) throw mvErr;

  const totalBase = (Array.isArray(mv) ? mv : []).reduce((s: number, r: any) => s + Number(r?.total_cost || 0), 0);
  const totalForeign = currency && currency !== baseCurrency ? (safeFx > 0 ? totalBase / safeFx : 0) : totalBase;

  const data: PrintablePurchaseReturnNoteData = {
    returnId: String((ret as any).id),
    purchaseOrderId: poId,
    supplierName: String((po as any)?.suppliers?.name || '').trim() || null,
    referenceNumber: String((po as any)?.reference_number || '').trim() || null,
    returnDate: String((ret as any)?.returned_at || (ret as any)?.created_at || new Date().toISOString()),
    reason: String((ret as any)?.reason || '').trim() || null,
    currency,
    fxRate: safeFx,
    baseCurrency,
    totalReturnForeign: currency === baseCurrency ? totalBase : totalForeign,
    totalReturnBase: totalBase,
    items: (Array.isArray(retItems) ? retItems : []).map((it: any) => ({
      itemId: String(it?.item_id || ''),
      itemName: String(it?.menu_items?.name || ''),
      quantity: Number(it?.quantity || 0) || 0,
    })),
  };

  const html = renderToString(createElement(PrintablePurchaseReturnNote as any, { data, brand, audit }));
  printContent(html, `مرتجع مشتريات #${String(data.returnId).slice(-8)}`);
  try {
    await supabase.from('system_audit_logs').insert({
      action: 'print',
      module: 'documents',
      details: `Printed Purchase Return ${String(data.returnId).slice(-8)}`,
      metadata: {
        docType: 'purchase_return_note',
        docNumber: String(data.returnId).slice(-8),
        status: 'Posted',
        sourceTable: 'purchase_returns',
        sourceId: data.returnId,
        template: 'PrintablePurchaseReturnNote',
        purchaseOrderId: data.purchaseOrderId,
      },
    } as any);
  } catch {
  }
};
