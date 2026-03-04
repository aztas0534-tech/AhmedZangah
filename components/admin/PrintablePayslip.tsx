import { AZTA_IDENTITY } from '../../config/identity';

export type PayslipData = {
    employeeName: string;
    employeeCode: string;
    jobTitle: string;
    nationalId: string;
    bankAccount: string;
    hiredDate: string;
    period: string;
    currency: string;
    basicSalary: number;
    absenceDays: number;
    absenceDeduction: number;
    overtimeHours: number;
    overtimeAddition: number;
    allowances: number;
    deductions: number;
    grossPay: number;
    netPay: number;
    arDeduction?: number;
    arBalance?: number;
    foreignAmount?: number;
    fxRate?: number;
    foreignCurrency?: string;
    companyName?: string;
    companyLogo?: string;
};

const fmt = (n: number) => {
    const v = Number(n || 0);
    try {
        return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    } catch {
        return v.toFixed(2);
    }
};

export default function PrintablePayslip({ data }: { data: PayslipData }) {
    const companyName = data.companyName || AZTA_IDENTITY.tradeNameAr;
    const currency = (data.currency || 'YER').toUpperCase();

    return (
        <div className="payslip-container" dir="rtl">
            <style>{`
        @media print {
          @page { size: A4; margin: 0; }
          body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        }
        .payslip-container {
          font-family: 'Tajawal', 'Cairo', 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
          max-width: 210mm;
          margin: 0 auto;
          background: white;
          color: #1E3A8A;
          line-height: 1.5;
          padding: 40px;
          border-top: 5px solid #1E3A8A;
        }

        /* Header */
        .ps-header {
          display: flex;
          justify-content: space-between;
          align-items: flex-start;
          margin-bottom: 30px;
          border-bottom: 2pt solid #1E3A8A;
          padding-bottom: 20px;
        }
        .ps-company h1 { font-size: 22px; font-weight: 800; margin: 0 0 5px 0; color: #0F172A; }
        .ps-title {
          text-align: left;
          background: #1E3A8A;
          color: white;
          padding: 15px 30px;
          border-radius: 8px;
        }
        .ps-title h2 { font-size: 22px; font-weight: 900; margin: 0; }
        .ps-title .ps-period { font-size: 14px; opacity: 0.85; margin-top: 5px; font-family: 'Courier New', monospace; }

        /* Employee Info */
        .ps-info-grid {
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 15px;
          margin-bottom: 25px;
          background: #f8fafc;
          padding: 20px;
          border-radius: 8px;
          border: 1.5pt solid #1E3A8A;
        }
        .ps-info-item { display: flex; flex-direction: column; }
        .ps-info-label { font-size: 11px; color: #64748b; font-weight: bold; margin-bottom: 3px; }
        .ps-info-value { font-size: 14px; font-weight: 600; color: #0F172A; }
        .tabular { font-variant-numeric: tabular-nums; font-family: 'Courier New', monospace; }

        /* Breakdown Table */
        .ps-table { width: 100%; border-collapse: separate; border-spacing: 0; margin-bottom: 20px; border-radius: 8px; overflow: hidden; border: 1.5pt solid #1E3A8A; }
        .ps-table th {
          background: #1E3A8A;
          color: white;
          font-weight: 700;
          text-align: center;
          padding: 12px 16px;
          font-size: 13px;
        }
        .ps-table th:first-child { text-align: right; }
        .ps-table td {
          padding: 12px 16px;
          border-bottom: 1pt solid #DBEAFE;
          vertical-align: middle;
          color: #1E40AF;
          font-size: 14px;
        }
        .ps-table tr:last-child td { border-bottom: none; }
        .ps-table tr:nth-child(even) { background-color: #f8fafc; }
        .ps-table .ps-positive { color: #059669; font-weight: 700; }
        .ps-table .ps-negative { color: #DC2626; font-weight: 700; }

        /* Net Box */
        .ps-net-box {
          background: #1E3A8A;
          color: white;
          padding: 20px 30px;
          border-radius: 8px;
          display: flex;
          justify-content: space-between;
          align-items: center;
          margin-bottom: 30px;
        }
        .ps-net-box .ps-net-label { font-size: 18px; font-weight: 800; }
        .ps-net-box .ps-net-value { font-size: 26px; font-weight: 900; font-family: 'Courier New', monospace; }

        /* Foreign Currency */
        .ps-fx-box {
          background: #f0f9ff;
          border: 1.5pt solid #1E3A8A;
          padding: 12px 20px;
          border-radius: 8px;
          display: flex;
          justify-content: space-between;
          align-items: center;
          margin-bottom: 30px;
          font-size: 14px;
        }

        /* Signatures */
        .ps-signatures {
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 30px;
          margin-top: 50px;
        }
        .ps-sig-box { border-top: 1px solid #cbd5e1; padding-top: 10px; text-align: center; }
        .ps-sig-label { font-size: 12px; font-weight: bold; color: #64748b; margin-bottom: 40px; }

        /* Footer */
        .ps-footer {
          margin-top: 40px;
          border-top: 1px dashed #cbd5e1;
          padding-top: 10px;
          display: flex;
          justify-content: space-between;
          font-size: 10px;
          color: #94a3b8;
        }
      `}</style>

            {/* Header */}
            <div className="ps-header">
                <div className="ps-company">
                    {data.companyLogo && <img src={data.companyLogo} alt="Logo" style={{ height: 80, marginBottom: 10 }} />}
                    <h1>{companyName}</h1>
                </div>
                <div className="ps-title">
                    <h2>كشف راتب</h2>
                    <div className="ps-period" dir="ltr">{data.period}</div>
                </div>
            </div>

            {/* Employee Info */}
            <div className="ps-info-grid">
                <div className="ps-info-item">
                    <span className="ps-info-label">اسم الموظف</span>
                    <span className="ps-info-value">{data.employeeName}</span>
                </div>
                <div className="ps-info-item">
                    <span className="ps-info-label">الكود</span>
                    <span className="ps-info-value tabular" dir="ltr">{data.employeeCode || '—'}</span>
                </div>
                <div className="ps-info-item">
                    <span className="ps-info-label">المسمى الوظيفي</span>
                    <span className="ps-info-value">{data.jobTitle || '—'}</span>
                </div>
                <div className="ps-info-item">
                    <span className="ps-info-label">رقم الهوية</span>
                    <span className="ps-info-value tabular" dir="ltr">{data.nationalId || '—'}</span>
                </div>
                <div className="ps-info-item">
                    <span className="ps-info-label">الحساب البنكي</span>
                    <span className="ps-info-value tabular" dir="ltr">{data.bankAccount || '—'}</span>
                </div>
                <div className="ps-info-item">
                    <span className="ps-info-label">تاريخ التعيين</span>
                    <span className="ps-info-value tabular" dir="ltr">{data.hiredDate || '—'}</span>
                </div>
            </div>

            {/* Detailed Breakdown Table */}
            <table className="ps-table">
                <thead>
                    <tr>
                        <th style={{ width: '55%' }}>البند</th>
                        <th style={{ width: '22%' }}>التفاصيل</th>
                        <th style={{ width: '23%' }}>المبلغ ({currency})</th>
                    </tr>
                </thead>
                <tbody>
                    <tr>
                        <td style={{ fontWeight: 700 }}>الراتب الأساسي</td>
                        <td></td>
                        <td className="tabular" dir="ltr" style={{ fontWeight: 700 }}>{fmt(data.basicSalary)}</td>
                    </tr>

                    {data.absenceDays > 0 && (
                        <tr>
                            <td>خصم الغياب</td>
                            <td className="tabular" dir="ltr">{data.absenceDays} يوم</td>
                            <td className="tabular ps-negative" dir="ltr">-{fmt(data.absenceDeduction)}</td>
                        </tr>
                    )}

                    {data.overtimeHours > 0 && (
                        <tr>
                            <td>علاوة العمل الإضافي</td>
                            <td className="tabular" dir="ltr">{data.overtimeHours} ساعة</td>
                            <td className="tabular ps-positive" dir="ltr">+{fmt(data.overtimeAddition)}</td>
                        </tr>
                    )}

                    <tr style={{ background: '#f0f9ff' }}>
                        <td style={{ fontWeight: 700 }}>إجمالي الراتب (بعد الغياب والإضافي)</td>
                        <td></td>
                        <td className="tabular" dir="ltr" style={{ fontWeight: 700 }}>{fmt(data.grossPay)}</td>
                    </tr>

                    {data.allowances > 0 && (
                        <tr>
                            <td>إجمالي البدلات</td>
                            <td></td>
                            <td className="tabular ps-positive" dir="ltr">+{fmt(data.allowances)}</td>
                        </tr>
                    )}

                    {data.deductions > 0 && (
                        <tr>
                            <td>إجمالي الاستقطاعات (ضرائب + سلف + خصومات)</td>
                            <td></td>
                            <td className="tabular ps-negative" dir="ltr">-{fmt(data.deductions)}</td>
                        </tr>
                    )}

                    {(data.arDeduction || 0) > 0 && (
                        <tr>
                            <td>خصم مبيعات آجلة (سداد مديونية)</td>
                            <td className="tabular" dir="ltr" style={{ fontSize: 11, color: '#64748b' }}>
                                المتبقي: {fmt(data.arBalance || 0)}
                            </td>
                            <td className="tabular ps-negative" dir="ltr">-{fmt(data.arDeduction || 0)}</td>
                        </tr>
                    )}
                </tbody>
            </table>

            {/* Net Pay Box */}
            <div className="ps-net-box">
                <div className="ps-net-label">صافي الراتب المستحق</div>
                <div className="ps-net-value" dir="ltr">{fmt(data.netPay)} <span style={{ fontSize: 14 }}>{currency}</span></div>
            </div>

            {/* Foreign Currency Info */}
            {data.foreignCurrency && data.foreignCurrency !== currency && Number(data.foreignAmount || 0) > 0 && (
                <div className="ps-fx-box">
                    <div>
                        <span style={{ fontWeight: 700 }}>المبلغ بالعملة الأصلية</span>
                        <span style={{ color: '#64748b', fontSize: 12, marginRight: 10 }}>
                            (سعر الصرف: {data.fxRate})
                        </span>
                    </div>
                    <div className="tabular" style={{ fontWeight: 700, fontSize: 18 }} dir="ltr">
                        {fmt(data.foreignAmount || 0)} {data.foreignCurrency}
                    </div>
                </div>
            )}

            {/* Signatures */}
            <div className="ps-signatures">
                <div className="ps-sig-box">
                    <div className="ps-sig-label">المحاسب</div>
                </div>
                <div className="ps-sig-box">
                    <div className="ps-sig-label">المدير المالي</div>
                </div>
                <div className="ps-sig-box">
                    <div className="ps-sig-label">الموظف (استلام)</div>
                </div>
            </div>

            {/* Footer */}
            <div className="ps-footer">
                <div>
                    تمت الطباعة بواسطة النظام في <span dir="ltr" className="tabular">{new Date().toLocaleString('en-GB')}</span>
                </div>
                <div>
                    Generated by {companyName}
                </div>
            </div>
        </div>
    );
}
