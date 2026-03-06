import { createElement } from 'react';
import { renderToString } from 'react-dom/server';
import { getSupabaseClient } from '../supabase';
import { printContent } from './printUtils';
import { amountToArabicWords } from './amountWordsAr';
import PrintableReceiptVoucher from '../components/admin/vouchers/PrintableReceiptVoucher';
import PrintablePaymentVoucher from '../components/admin/vouchers/PrintablePaymentVoucher';
import PrintableJournalVoucher from '../components/admin/vouchers/PrintableJournalVoucher';
import type { VoucherLine } from '../components/admin/vouchers/PrintableVoucherBase';

type Brand = {
  name?: string;
  address?: string;
  contactNumber?: string;
  logoUrl?: string;
  branchName?: string;
  branchCode?: string;
};

const fmtTime = (iso: string) => {
  return iso;
};

const paymentMethodLabel = (method: string) => {
  const m = String(method || '').trim().toLowerCase();
  if (m === 'cash') return 'نقدًا';
  if (m === 'kuraimi' || m === 'bank') return 'حسابات بنكية';
  if (m === 'network' || m === 'card') return 'حوالات';
  if (m === 'ar') return 'آجل';
  if (m === 'mixed') return 'متعدد';
  return method || null;
};

const resolveAdminDisplayName = async (userId: string) => {
  const supabase = getSupabaseClient();
  if (!supabase) return null;
  const id = String(userId || '').trim();
  if (!id) return null;
  try {
    const { data, error } = await supabase
      .from('admin_users')
      .select('full_name,username,email')
      .eq('auth_user_id', id)
      .maybeSingle();
    if (error) return null;
    const fullName = String((data as any)?.full_name || '').trim();
    const username = String((data as any)?.username || '').trim();
    const email = String((data as any)?.email || '').trim();
    return fullName || username || email || null;
  } catch {
    return null;
  }
};

const resolveShiftInfo = async (shiftId: string | null | undefined): Promise<{ number: number | null, name: string | null }> => {
  const supabase = getSupabaseClient();
  if (!supabase) return { number: null, name: null };
  const id = String(shiftId || '').trim();
  if (!id) return { number: null, name: null };
  try {
    const { data, error } = await supabase
      .from('cash_shifts')
      .select('shift_number, closed_by')
      .eq('id', id)
      .maybeSingle();
    if (error) return { number: null, name: null };
    const n = (data as any)?.shift_number;
    const v = n === null || n === undefined ? null : Number(n);
    const num = Number.isFinite(v as any) && (v as number) > 0 ? Math.trunc(v as number) : null;
    return { number: num, name: num ? `صندوق ${num}` : null };
  } catch {
    return { number: null, name: null };
  }
};

const fetchJournalEntryWithLines = async (entryId: string) => {
  const supabase = getSupabaseClient();
  if (!supabase) throw new Error('Supabase غير مهيأ.');

  const { data: entry, error: eErr } = await supabase
    .from('journal_entries')
    .select('id,entry_date,memo,status,document_id,source_table,source_id,source_event,branch_id,company_id,created_by,shift_id')
    .eq('id', entryId)
    .maybeSingle();
  if (eErr) throw eErr;
  if (!entry) throw new Error('القيد غير موجود.');

  const documentId = String((entry as any).document_id || '');
  if (!documentId) throw new Error('القيد غير مرتبط بوثيقة محاسبية.');

  const { data: docRow, error: docErr } = await supabase
    .from('accounting_documents')
    .select('id,document_type,source_table,source_id')
    .eq('id', documentId)
    .maybeSingle();
  if (docErr) throw docErr;

  const { data: docNumber, error: dnErr } = await supabase.rpc('ensure_accounting_document_number', { p_document_id: documentId });
  if (dnErr) throw dnErr;

  const { data: lines, error: lErr } = await supabase
    .from('journal_lines')
    .select('debit,credit,line_memo,currency_code,fx_rate,foreign_amount,account_id,party_id,chart_of_accounts(code,name),financial_parties(name)')
    .eq('journal_entry_id', entryId)
    .order('id', { ascending: true });
  if (lErr) throw lErr;

  const mappedLines: VoucherLine[] = (Array.isArray(lines) ? lines : []).map((l: any) => {
    const cur = String(l?.currency_code || '').trim().toUpperCase();
    return {
      accountCode: String(l?.chart_of_accounts?.code || ''),
      accountName: String(l?.chart_of_accounts?.name || ''),
      debit: Number(l?.debit || 0),
      credit: Number(l?.credit || 0),
      foreignDebit: Number(l?.debit || 0) > 0 ? Number(l?.foreign_amount || 0) : null,
      foreignCredit: Number(l?.credit || 0) > 0 ? Number(l?.foreign_amount || 0) : null,
      currency: cur || null,
      memo: l?.line_memo ?? null,
    };
  });

  const debitLine = mappedLines.find((l) => Number(l.debit || 0) > 0);
  const creditLine = mappedLines.find((l) => Number(l.credit || 0) > 0);
  const toAccount = debitLine ? `${String(debitLine.accountCode || '').trim()} — ${String(debitLine.accountName || '').trim()}`.trim() : null;
  const fromAccount = creditLine ? `${String(creditLine.accountCode || '').trim()} — ${String(creditLine.accountName || '').trim()}`.trim() : null;

  const status = String((entry as any)?.status || '').trim().toLowerCase();
  const statusLabel = status === 'draft' ? 'مسودة' : status === 'posted' ? 'مُرحّل' : status === 'voided' ? 'مبطل' : (status || null);
  const currencyCandidates = (Array.isArray(lines) ? lines : [])
    .map((l: any) => String(l?.currency_code || '').trim().toUpperCase())
    .filter(Boolean);
  const currency = currencyCandidates.length ? currencyCandidates[0] : null;

  // Resolve party name: first from party_ledger_entries, then from journal_lines.party_id
  let partyName: string | null = null;
  try {
    const { data: ple, error: pleErr } = await supabase
      .from('party_ledger_entries')
      .select('party_id, financial_parties(name)')
      .eq('journal_entry_id', entryId)
      .order('occurred_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (!pleErr) {
      const n = (ple as any)?.financial_parties?.name;
      partyName = typeof n === 'string' ? n.trim() : null;
    }
  } catch {
  }
  // Fallback: resolve party from journal_lines directly (works for draft vouchers)
  if (!partyName) {
    const rawLines = Array.isArray(lines) ? lines : [];
    for (const l of rawLines) {
      const pName = (l as any)?.financial_parties?.name;
      if (typeof pName === 'string' && pName.trim()) {
        partyName = pName.trim();
        break;
      }
    }
  }

  let paymentMethod: string | null = null;
  let paymentReferenceNumber: string | null = null;
  let senderName: string | null = null;
  let senderPhone: string | null = null;
  let receivedBy: string | null = null;
  let shiftId: string | null = String((entry as any)?.shift_id || '').trim() || null;
  let shiftNumber: number | null = null;
  let shiftName: string | null = null;

  if (shiftId) {
    const sInfo = await resolveShiftInfo(shiftId);
    shiftNumber = sInfo.number;
    shiftName = sInfo.name;
  }

  const entryCreatedBy = String((entry as any)?.created_by || '').trim();
  if (entryCreatedBy) {
    receivedBy = await resolveAdminDisplayName(entryCreatedBy);
  }

  const sourceTable = String((entry as any)?.source_table || '').trim().toLowerCase();
  const sourceId = String((entry as any)?.source_id || '').trim();
  if (sourceTable === 'payments' && sourceId) {
    try {
      const { data: pay, error: pErr } = await supabase
        .from('payments')
        .select('id,method,created_by,data,reference_table,reference_id,occurred_at,shift_id')
        .eq('id', sourceId)
        .maybeSingle();
      if (!pErr && pay) {
        paymentMethod = paymentMethodLabel(String((pay as any)?.method || '')) as any;
        const payShiftId = String((pay as any)?.shift_id || '').trim() || null;
        if (!shiftId && payShiftId) {
          shiftId = payShiftId;
          const sInfo = await resolveShiftInfo(shiftId);
          shiftNumber = sInfo.number;
          shiftName = sInfo.name;
        }
        const pdata = (pay as any)?.data || {};
        const ref = String(pdata?.referenceNumber || pdata?.reference_number || pdata?.paymentReferenceNumber || '').trim();
        paymentReferenceNumber = ref || null;
        const sn = String(pdata?.senderName || pdata?.sender_name || '').trim();
        senderName = sn || null;
        const sp = String(pdata?.senderPhone || pdata?.sender_phone || '').trim();
        senderPhone = sp || null;
        if (!receivedBy) {
          const payCreatedBy = String((pay as any)?.created_by || '').trim();
          if (payCreatedBy) receivedBy = await resolveAdminDisplayName(payCreatedBy);
        }
      }
    } catch {
    }
  }

  let foreignAmount: number | null = null;
  let fxRate: number | null = null;
  const rawLines = Array.isArray(lines) ? lines : [];
  for (const l of rawLines) {
    const fa = Number((l as any)?.foreign_amount || 0);
    const fr = Number((l as any)?.fx_rate || 0);
    if (fa > 0 && fr > 0) {
      foreignAmount = fa;
      fxRate = fr;
      break;
    }
  }

  let baseCurrency: string | null = null;
  try {
    const { data: baseCurRow } = await supabase.rpc('get_base_currency');
    baseCurrency = baseCurRow ? String(baseCurRow).trim().toUpperCase() : null;
  } catch { /* ignore */ }

  return {
    entry: entry as any,
    document: docRow as any,
    documentId,
    documentNumber: String(docNumber || ''),
    lines: mappedLines,
    statusLabel,
    currency,
    partyName,
    paymentMethod,
    paymentReferenceNumber,
    senderName,
    senderPhone,
    receivedBy,
    toAccount: toAccount || null,
    fromAccount: fromAccount || null,
    shiftId,
    shiftNumber,
    shiftName,
    foreignAmount,
    fxRate,
    baseCurrency,
  };
};

export const printReceiptVoucherByEntryId = async (entryId: string, brand?: Brand) => {
  const supabase = getSupabaseClient();
  if (!supabase) throw new Error('Supabase غير مهيأ.');

  const id = String(entryId || '').trim();
  if (!id) throw new Error('معرف القيد غير صالح.');

  const bundle = await fetchJournalEntryWithLines(id);
  const docType = String((bundle as any)?.document?.document_type || '').toLowerCase();
  if (docType !== 'receipt') throw new Error('هذا القيد ليس سند قبض.');

  const baseAmount = bundle.lines.reduce((s, l) => s + Number(l.debit || 0), 0);
  const currency = bundle.currency || 'YER';
  // If foreign amount exists, display it (the transaction currency amount), not the base amount
  const displayAmount = (bundle.foreignAmount && bundle.foreignAmount > 0) ? bundle.foreignAmount : baseAmount;
  const currencyLabel = currency === 'YER' ? 'ريال يمني' : currency === 'SAR' ? 'ريال' : currency === 'USD' ? 'دولار' : 'عملة';
  const data = {
    voucherNumber: bundle.documentNumber,
    status: bundle.statusLabel,
    referenceId: id,
    date: fmtTime(String(bundle.entry.entry_date || '')),
    memo: String(bundle.entry.memo || '').trim() || null,
    currency,
    amount: displayAmount,
    amountWords: amountToArabicWords(displayAmount, currencyLabel),
    lines: bundle.lines,
    partyName: (bundle as any).partyName || null,
    paymentMethod: (bundle as any).paymentMethod || null,
    paymentReferenceNumber: (bundle as any).paymentReferenceNumber || null,
    senderName: (bundle as any).senderName || null,
    senderPhone: (bundle as any).senderPhone || null,
    receivedBy: (bundle as any).receivedBy || null,
    toAccount: (bundle as any).toAccount || null,
    fromAccount: (bundle as any).fromAccount || null,
    shiftId: (bundle as any).shiftId || null,
    shiftNumber: (bundle as any).shiftNumber ?? null,
    shiftName: (bundle as any).shiftName ?? null,
    foreignAmount: (bundle as any).foreignAmount ?? null,
    fxRate: (bundle as any).fxRate ?? null,
    baseCurrency: (bundle as any).baseCurrency ?? null,
  };

  const html = renderToString(createElement(PrintableReceiptVoucher as any, { data, brand }));
  printContent(html, `سند قبض #${bundle.documentNumber}`);
  await supabase.rpc('mark_accounting_document_printed', { p_document_id: bundle.documentId, p_template: 'PrintableReceiptVoucher' });
};

export const printPaymentVoucherByEntryId = async (entryId: string, brand?: Brand) => {
  const supabase = getSupabaseClient();
  if (!supabase) throw new Error('Supabase غير مهيأ.');

  const id = String(entryId || '').trim();
  if (!id) throw new Error('معرف القيد غير صالح.');

  const bundle = await fetchJournalEntryWithLines(id);
  const docType = String((bundle as any)?.document?.document_type || '').toLowerCase();
  if (docType !== 'payment') throw new Error('هذا القيد ليس سند صرف.');

  const baseAmount = bundle.lines.reduce((s, l) => s + Number(l.debit || 0), 0);
  const currency = bundle.currency || 'YER';
  // If foreign amount exists, display it (the transaction currency amount), not the base amount
  const displayAmount = (bundle.foreignAmount && bundle.foreignAmount > 0) ? bundle.foreignAmount : baseAmount;
  const currencyLabel = currency === 'YER' ? 'ريال يمني' : currency === 'SAR' ? 'ريال' : currency === 'USD' ? 'دولار' : 'عملة';
  const data = {
    voucherNumber: bundle.documentNumber,
    status: bundle.statusLabel,
    referenceId: id,
    date: fmtTime(String(bundle.entry.entry_date || '')),
    memo: String(bundle.entry.memo || '').trim() || null,
    currency,
    amount: displayAmount,
    amountWords: amountToArabicWords(displayAmount, currencyLabel),
    lines: bundle.lines,
    partyName: (bundle as any).partyName || null,
    paymentMethod: (bundle as any).paymentMethod || null,
    paymentReferenceNumber: (bundle as any).paymentReferenceNumber || null,
    senderName: (bundle as any).senderName || null,
    senderPhone: (bundle as any).senderPhone || null,
    receivedBy: (bundle as any).receivedBy || null,
    toAccount: (bundle as any).toAccount || null,
    fromAccount: (bundle as any).fromAccount || null,
    shiftId: (bundle as any).shiftId || null,
    shiftNumber: (bundle as any).shiftNumber ?? null,
    shiftName: (bundle as any).shiftName ?? null,
    foreignAmount: (bundle as any).foreignAmount ?? null,
    fxRate: (bundle as any).fxRate ?? null,
    baseCurrency: (bundle as any).baseCurrency ?? null,
  };

  const html = renderToString(createElement(PrintablePaymentVoucher as any, { data, brand }));
  printContent(html, `سند صرف #${bundle.documentNumber}`);
  await supabase.rpc('mark_accounting_document_printed', { p_document_id: bundle.documentId, p_template: 'PrintablePaymentVoucher' });
};

export const printReceiptVoucherByPaymentId = async (paymentId: string, brand?: Brand) => {
  const supabase = getSupabaseClient();
  if (!supabase) throw new Error('Supabase غير مهيأ.');

  const pid = String(paymentId || '').trim();
  if (!pid) throw new Error('معرف الدفعة غير صالح.');

  const { data: pay, error: pErr } = await supabase
    .from('payments')
    .select('id,direction,method,amount,currency,occurred_at,reference_table,reference_id,branch_id,shift_id,data,created_by')
    .eq('id', pid)
    .maybeSingle();
  if (pErr) throw pErr;
  if (!pay) throw new Error('الدفعة غير موجودة.');
  if (String((pay as any).direction || '') !== 'in') throw new Error('هذه ليست دفعة قبض.');

  const { data: entryRow, error: jeErr } = await supabase
    .from('journal_entries')
    .select('id')
    .eq('source_table', 'payments')
    .eq('source_id', pid)
    .order('entry_date', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (jeErr) throw jeErr;
  const entryId = String((entryRow as any)?.id || '');
  if (!entryId) throw new Error('تعذر العثور على القيد المرتبط بهذه الدفعة.');

  const bundle = await fetchJournalEntryWithLines(entryId);
  const amount = Number((pay as any).amount || 0);
  const currency = String((pay as any).currency || '').toUpperCase() || '';
  const shiftId = String((pay as any)?.shift_id || '').trim() || null;
  const sInfo = await resolveShiftInfo(shiftId);
  const shiftNumber = sInfo.number;
  const shiftName = sInfo.name;
  const data = {
    voucherNumber: bundle.documentNumber,
    status: 'Posted',
    referenceId: pid,
    date: fmtTime(String((pay as any).occurred_at || bundle.entry.entry_date || '')),
    memo: String(bundle.entry.memo || '').trim() || null,
    currency,
    amount,
    amountWords: amountToArabicWords(amount, currency === 'YER' ? 'ريال' : 'عملة'),
    lines: bundle.lines,
    partyName: (bundle as any).partyName || null,
    paymentMethod: paymentMethodLabel(String((pay as any)?.method || '')) as any,
    paymentReferenceNumber: String(((pay as any)?.data?.referenceNumber || (pay as any)?.data?.reference_number || '')).trim() || null,
    senderName: String(((pay as any)?.data?.senderName || (pay as any)?.data?.sender_name || '')).trim() || null,
    senderPhone: String(((pay as any)?.data?.senderPhone || (pay as any)?.data?.sender_phone || '')).trim() || null,
    receivedBy: (bundle as any).receivedBy || null,
    toAccount: (bundle as any).toAccount || null,
    fromAccount: (bundle as any).fromAccount || null,
    shiftId,
    shiftNumber,
    shiftName,
    foreignAmount: (bundle as any).foreignAmount ?? null,
    fxRate: (bundle as any).fxRate ?? null,
    baseCurrency: (bundle as any).baseCurrency ?? null,
  };

  const html = renderToString(createElement(PrintableReceiptVoucher as any, { data, brand }));
  printContent(html, `سند قبض #${bundle.documentNumber}`);
  await supabase.rpc('mark_accounting_document_printed', { p_document_id: bundle.documentId, p_template: 'PrintableReceiptVoucher' });
};

export const printPaymentVoucherByPaymentId = async (paymentId: string, brand?: Brand) => {
  const supabase = getSupabaseClient();
  if (!supabase) throw new Error('Supabase غير مهيأ.');

  const pid = String(paymentId || '').trim();
  if (!pid) throw new Error('معرف الدفعة غير صالح.');

  const { data: pay, error: pErr } = await supabase
    .from('payments')
    .select('id,direction,method,amount,currency,occurred_at,reference_table,reference_id,branch_id,shift_id,data,created_by')
    .eq('id', pid)
    .maybeSingle();
  if (pErr) throw pErr;
  if (!pay) throw new Error('الدفعة غير موجودة.');
  if (String((pay as any).direction || '') !== 'out') throw new Error('هذه ليست دفعة صرف.');

  const { data: entryRow, error: jeErr } = await supabase
    .from('journal_entries')
    .select('id')
    .eq('source_table', 'payments')
    .eq('source_id', pid)
    .order('entry_date', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (jeErr) throw jeErr;
  const entryId = String((entryRow as any)?.id || '');
  if (!entryId) throw new Error('تعذر العثور على القيد المرتبط بهذه الدفعة.');

  const bundle = await fetchJournalEntryWithLines(entryId);
  const amount = Number((pay as any).amount || 0);
  const currency = String((pay as any).currency || '').toUpperCase() || '';
  const shiftId = String((pay as any)?.shift_id || '').trim() || null;
  const sInfo = await resolveShiftInfo(shiftId);
  const shiftNumber = sInfo.number;
  const shiftName = sInfo.name;
  const data = {
    voucherNumber: bundle.documentNumber,
    status: 'Posted',
    referenceId: pid,
    date: fmtTime(String((pay as any).occurred_at || bundle.entry.entry_date || '')),
    memo: String(bundle.entry.memo || '').trim() || null,
    currency,
    amount,
    amountWords: amountToArabicWords(amount, currency === 'YER' ? 'ريال' : 'عملة'),
    lines: bundle.lines,
    partyName: (bundle as any).partyName || null,
    paymentMethod: paymentMethodLabel(String((pay as any)?.method || '')) as any,
    paymentReferenceNumber: String(((pay as any)?.data?.referenceNumber || (pay as any)?.data?.reference_number || '')).trim() || null,
    senderName: String(((pay as any)?.data?.senderName || (pay as any)?.data?.sender_name || '')).trim() || null,
    senderPhone: String(((pay as any)?.data?.senderPhone || (pay as any)?.data?.sender_phone || '')).trim() || null,
    receivedBy: (bundle as any).receivedBy || null,
    toAccount: (bundle as any).toAccount || null,
    fromAccount: (bundle as any).fromAccount || null,
    shiftId,
    shiftNumber,
    shiftName,
    foreignAmount: (bundle as any).foreignAmount ?? null,
    fxRate: (bundle as any).fxRate ?? null,
    baseCurrency: (bundle as any).baseCurrency ?? null,
  };

  const html = renderToString(createElement(PrintablePaymentVoucher as any, { data, brand }));
  printContent(html, `سند صرف #${bundle.documentNumber}`);
  await supabase.rpc('mark_accounting_document_printed', { p_document_id: bundle.documentId, p_template: 'PrintablePaymentVoucher' });
};

export const printJournalVoucherByEntryId = async (entryId: string, brand?: Brand) => {
  const supabase = getSupabaseClient();
  if (!supabase) throw new Error('Supabase غير مهيأ.');

  const id = String(entryId || '').trim();
  if (!id) throw new Error('معرف القيد غير صالح.');

  const bundle = await fetchJournalEntryWithLines(id);
  const total = bundle.lines.reduce((s, l) => s + Number(l.debit || 0), 0);
  const data = {
    voucherNumber: bundle.documentNumber,
    status: bundle.statusLabel,
    referenceId: id,
    date: fmtTime(String(bundle.entry.entry_date || '')),
    memo: String(bundle.entry.memo || '').trim() || null,
    currency: bundle.currency || 'YER',
    amount: total,
    amountWords: amountToArabicWords(total, (bundle.currency || 'YER') === 'YER' ? 'ريال' : 'عملة'),
    lines: bundle.lines,
    partyName: (bundle as any).partyName || null,
    paymentMethod: (bundle as any).paymentMethod || null,
    paymentReferenceNumber: (bundle as any).paymentReferenceNumber || null,
    senderName: (bundle as any).senderName || null,
    senderPhone: (bundle as any).senderPhone || null,
    receivedBy: (bundle as any).receivedBy || null,
    toAccount: (bundle as any).toAccount || null,
    fromAccount: (bundle as any).fromAccount || null,
  };

  const html = renderToString(createElement(PrintableJournalVoucher as any, { data, brand }));
  printContent(html, `قيد يومية #${bundle.documentNumber}`);
  await supabase.rpc('mark_accounting_document_printed', { p_document_id: bundle.documentId, p_template: 'PrintableJournalVoucher' });
};

