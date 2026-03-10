import React, { useState, useEffect } from 'react';
import { formatDateOnly } from '../../../utils/printUtils';
import { formatSourceRefAr, localizeOpenStatusAr, shortId } from '../../../utils/displayLabels';
import { AZTA_IDENTITY } from '../../../config/identity';
import QRCode from 'qrcode';

type Brand = {
  name?: string;
  address?: string;
  contactNumber?: string;
  logoUrl?: string;
  branchName?: string;
  branchCode?: string;
};

type StatementRow = {
  occurred_at: string;
  journal_entry_id: string;
  journal_line_id: string;
  account_code: string;
  account_name: string;
  direction: 'debit' | 'credit';
  foreign_amount: number | null;
  base_amount: number;
  currency_code: string;
  fx_rate: number | null;
  memo: string | null;
  source_table: string | null;
  source_id: string | null;
  source_event: string | null;
  running_balance: number;
  open_base_amount: number | null;
  open_foreign_amount: number | null;
  open_status: string | null;
  running_foreign_balance?: number | null;
  allocations?: any;
};

const fmt = (n: number) => {
  const v = Number(n || 0);
  try {
    return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  } catch {
    return v.toFixed(2);
  }
};

export default function PrintablePartyLedgerStatement(props: {
  brand?: Brand;
  partyId: string;
  partyName: string;
  accountCode?: string | null;
  currency?: string | null;
  start?: string | null;
  end?: string | null;
  rows: StatementRow[];
  printCurrencyCode?: string | null;
  printFxRate?: number | null;
  baseCurrencyCode?: string | null;
}) {
  const { brand, partyId, partyName, accountCode, currency, start, end, rows, printCurrencyCode, baseCurrencyCode } = props;
  const selectedCode = String(printCurrencyCode || '').trim().toUpperCase();
  const baseCode = String(baseCurrencyCode || '').trim().toUpperCase();
  const filteredRows = selectedCode
    ? rows.filter((r) => String(r.currency_code || '').trim().toUpperCase() === selectedCode)
    : rows;

  const amountInRowCurrency = (r: StatementRow) => {
    const fa = r.foreign_amount;
    if (fa == null) return Number(r.base_amount || 0) || 0;
    return Number(fa || 0) || 0;
  };

  const periodText = [start ? formatDateOnly(start) : null, end ? formatDateOnly(end) : null]
    .filter(Boolean)
    .join(' — ');

  let closingBalance = 0;
  if (filteredRows.length > 0) {
      const lastRow = filteredRows[filteredRows.length - 1];
      closingBalance = Number((lastRow.running_foreign_balance ?? lastRow.running_balance) ?? 0);
  }

  const systemName = AZTA_IDENTITY?.tradeNameAr || 'مؤسسة أزتا';
  const resolvedLogoUrl = brand?.logoUrl || '/logo.png';
  const resolvedCompanyAddress = brand?.address || 'الرياض, المملكة العربية السعودية';
  const resolvedCompanyPhone = brand?.contactNumber || '';
  const resolvedVatNumber = '310931168100003';
  const qrData = 'ZATCA-QR-PLACEHOLDER';

  const thermalPaperWidth = '80mm';

  return (
        <div className="thermal-invoice" dir="rtl">
            <style>{`
                .thermal-invoice {
                    font-family: 'Tahoma', 'Arial', sans-serif;
                    font-size: 12px;
                    line-height: 1.4;
                    color: #000;
                    width: ${thermalPaperWidth};
                    max-width: ${thermalPaperWidth};
                    margin: 0 auto;
                    padding: 0 2px;
                    background: white;
                }
                @media print {
                    @page {
                        margin: 0;
                        size: auto;
                    }
                    body {
                        margin: 0;
                        padding: 0;
                    }
                    .thermal-invoice {
                        width: 100%;
                        max-width: none;
                        padding: 5px;
                    }
                }
                .text-center { text-align: center; }
                .text-right { text-align: right; }
                .text-left { text-align: left; }
                .font-bold { font-weight: bold; }
                .text-xs { font-size: 11px; }
                .text-sm { font-size: 12px; }
                .text-lg { font-size: 15px; }
                .text-xl { font-size: 18px; }
                .mb-1 { margin-bottom: 4px; }
                .mb-2 { margin-bottom: 8px; }
                .mt-1 { margin-top: 4px; }
                .mt-2 { margin-top: 8px; }
                .py-1 { padding-top: 4px; padding-bottom: 4px; }
                .border-b { border-bottom: 1px dashed #000; }
                .border-t { border-top: 1px dashed #000; }
                .border-y { border-top: 1px dashed #000; border-bottom: 1px dashed #000; }
                .flex { display: flex; justify-content: space-between; align-items: baseline; }
                .tabular { font-variant-numeric: tabular-nums; font-family: 'Courier New', monospace; letter-spacing: -0.5px; }
                .logo-img { height: 100px; margin-bottom: 5px; display: block; margin-left: auto; margin-right: auto; }
                table { width: 100%; border-collapse: collapse; }
                th { text-align: right; font-size: 11px; border-bottom: 1px dashed #000; padding-bottom: 4px; }
                td { padding: 3px 0; vertical-align: top; }
                .item-name { font-weight: bold; margin-bottom: 2px; }
                .item-meta { font-size: 10px; color: #444; }
                .total-box { border: 2px solid #000; padding: 8px; margin-top: 10px; border-radius: 4px; }
            `}</style>

            <div className="text-center mb-2">
                {resolvedLogoUrl && <img src={resolvedLogoUrl} alt="Logo" className="logo-img" />}
                <div className="font-bold text-lg mb-1">{systemName}</div>
                {brand?.name && brand.name !== systemName && <div className="text-sm mb-1">{brand.name}</div>}
                <div className="text-xs">{resolvedCompanyAddress}</div>
                {resolvedCompanyPhone && <div className="text-xs" dir="ltr">{resolvedCompanyPhone}</div>}
                {resolvedVatNumber && <div className="text-xs mt-1 font-bold">الرقم الضريبي: <span dir="ltr" className="tabular">{resolvedVatNumber}</span></div>}
            </div>

            <div className="text-center border-y py-1 mb-2">
                <div className="font-bold text-lg">كشف حساب طرف</div>
                <div className="text-xs mt-1">LEDGER STATEMENT</div>
            </div>

            <div className="mb-2 text-sm">
                <div className="flex">
                    <span>الاسم:</span>
                    <span className="font-bold">{partyName || '—'}</span>
                </div>
                <div className="flex">
                    <span>الرقم:</span>
                    <span className="tabular" dir="ltr">{shortId(partyId)}</span>
                </div>
                {periodText && (
                    <div className="flex">
                        <span>الفترة:</span>
                        <span className="tabular" dir="ltr">{periodText}</span>
                    </div>
                )}
                <div className="flex">
                    <span>العملة:</span>
                    <span className="tabular" dir="ltr">{selectedCode || baseCode || '—'}</span>
                </div>
            </div>

            <table className="mb-2">
                <thead>
                    <tr>
                        <th style={{ width: '25%' }}>التاريخ</th>
                        <th style={{ width: '35%' }}>البيان</th>
                        <th style={{ width: '20%', textAlign: 'center' }}>المبلغ</th>
                        <th style={{ width: '20%', textAlign: 'left' }}>الرصيد</th>
                    </tr>
                </thead>
                <tbody>
                    {filteredRows.length === 0 ? (
                        <tr>
                            <td colSpan={4} className="text-center py-4">لا توجد حركات</td>
                        </tr>
                    ) : (
                        filteredRows.map((r, i) => {
                            const amt = amountInRowCurrency(r);
                            const isDebit = r.direction === 'debit';
                            const dt = new Date(r.occurred_at);
                            const bal = Number((r.running_foreign_balance ?? r.running_balance) ?? 0);
                            
                            return (
                                <tr key={r.journal_line_id || i}>
                                    <td className="tabular text-xs">
                                        <div dir="ltr">{dt.toLocaleDateString('en-GB')}</div>
                                        <div className="text-[10px] color-[#444]" dir="ltr">{dt.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}</div>
                                    </td>
                                    <td>
                                        <div className="item-name font-normal">{r.account_name}</div>
                                        <div className="item-meta">{formatSourceRefAr(r.source_table, r.source_event, r.source_id)}</div>
                                    </td>
                                    <td className="text-center tabular" dir="ltr">
                                        <span className={isDebit ? 'font-bold' : ''}>
                                            {isDebit ? '' : '-'}{fmt(amt)}
                                        </span>
                                    </td>
                                    <td className="text-left font-bold tabular" dir="ltr">
                                        {fmt(bal)}
                                    </td>
                                </tr>
                            );
                        })
                    )}
                </tbody>
            </table>

            <div className="total-box text-center mb-4">
                <div className="text-sm font-bold mb-1">الرصيد الختامي</div>
                <div className="text-xl font-bold tabular" dir="ltr">
                    {fmt(closingBalance)} {selectedCode || baseCode}
                </div>
                <div className="text-xs mt-1">
                    {closingBalance < 0 ? 'دائن' : closingBalance > 0 ? 'مدين' : 'متزن'}
                </div>
            </div>

            <div className="text-center mb-4">
                <div style={{ display: 'inline-block', padding: '5px', background: 'white' }}>
                    <QRImage value={qrData} size={120} />
                </div>
            </div>

            <div className="text-center text-xs mt-2">
                <div className="mt-1 tabular" dir="ltr">{new Date().toLocaleString('en-GB')}</div>
            </div>
        </div>
    );
}

const QRImage: React.FC<{ value: string; size?: number }> = ({ value, size = 120 }) => {
    const [url, setUrl] = useState<string>('');
    useEffect(() => {
        let active = true;
        (async () => {
            try {
                const dataUrl = await QRCode.toDataURL(value, { width: size, margin: 1 });
                if (active) setUrl(dataUrl);
            } catch {
                if (active) setUrl('');
            }
        })();
        return () => { active = false; };
    }, [value, size]);
    if (!url) return null;
    return <img src={url} alt="QR" style={{ width: size, height: size }} />;
};
