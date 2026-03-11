import React from 'react';
import { Order } from '../../types';
import DocumentAuditFooter from './documents/DocumentAuditFooter';
import { DocumentAuditInfo } from '../../utils/documentStandards';
import PrintCopyBadge from './documents/PrintCopyBadge';

interface PrintableOrderProps {
    order: Order;
    language?: 'ar' | 'en';
    companyName?: string;
    companyAddress?: string;
    companyPhone?: string;
    logoUrl?: string;
    audit?: DocumentAuditInfo | null;
    printNumber?: number | null;
}

const PrintableOrder: React.FC<PrintableOrderProps> = ({ order, language = 'ar', companyName = '', companyAddress = '', companyPhone = '', logoUrl = '', audit, printNumber }) => {
    const storeName = companyName;

    const getStatusText = (status: string) => {
        const statusMap: Record<string, string> = language === 'en'
            ? {
                pending: 'Pending',
                preparing: 'Processing',
                out_for_delivery: 'Out for delivery',
                delivered: 'Delivered',
                scheduled: 'Scheduled',
            }
            : {
                pending: 'قيد الانتظار',
                preparing: 'قيد التجهيز',
                out_for_delivery: 'في الطريق',
                delivered: 'تم التسليم',
                scheduled: 'مجدول',
            };
        return statusMap[status] || status;
    };

    return (
        <div className="order-container" dir="rtl">
            <style>{`
                @media print {
                    @page { size: A5; margin: 0; }
                    body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
                }
                .order-container {
                    font-family: 'Tajawal', 'Cairo', 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                    width: 100%; background: white; color: #1E3A8A;
                    line-height: 1.2; padding: 3mm;
                    border-top: 3px solid #1E3A8A;
                    max-height: 210mm; overflow: hidden;
                }
                .header-section {
                    display: flex; justify-content: space-between; align-items: flex-start;
                    margin-bottom: 6px; border-bottom: 1.5pt solid #1E3A8A; padding-bottom: 4px;
                }
                .company-info { text-align: right; }
                .company-info h1 { font-size: 14px; font-weight: 800; margin: 0 0 2px 0; color: #0F172A; }
                .company-info p { margin: 1px 0; font-size: 8px; color: #1D4ED8; }
                
                .doc-title {
                    text-align: left; background: #f8fafc;
                    padding: 6px 12px; border-radius: 4px; border: 1pt solid #1E3A8A;
                }
                .doc-title h2 { font-size: 14px; font-weight: 900; color: #0F172A; margin: 0; text-transform: uppercase; letter-spacing: 0.3px; }
                .doc-title .ref-number { font-size: 9px; color: #64748b; margin-top: 2px; font-family: 'Courier New', monospace; }

                .info-grid {
                    display: grid; grid-template-columns: repeat(2, 1fr); gap: 4px;
                    margin-bottom: 6px; background: #f8fafc; padding: 4px 6px;
                    border-radius: 4px; border: 1pt solid #1E3A8A;
                }
                .info-item { display: flex; flex-direction: column; }
                .info-label { font-size: 7px; color: #64748b; font-weight: bold; margin-bottom: 1px; }
                .info-value { font-size: 9px; font-weight: 600; color: #0F172A; }
                .tabular { font-variant-numeric: tabular-nums; font-family: 'Courier New', monospace; }

                .lines-table { width: 100%; border-collapse: separate; border-spacing: 0; margin-bottom: 6px; font-size: 9px; border-radius: 4px; overflow: hidden; border: 1pt solid #1E3A8A; }
                .lines-table th { background: #1E3A8A; color: white; font-weight: 700; text-align: right; padding: 3px 4px; border-bottom: 1px solid #0F172A; font-size: 8px; }
                .lines-table td { padding: 3px 4px; border-bottom: 0.5pt solid #DBEAFE; vertical-align: top; color: #1E40AF; font-size: 9px; }
                .lines-table tr:last-child td { border-bottom: none; }
                .lines-table tr:nth-child(even) { background-color: #f8fafc; }
                .qty-badge { background: #e2e8f0; padding: 2px 4px; border-radius: 3px; font-weight: bold; font-family: 'Courier New', monospace; }

                .notes-box { background: #fef2f2; border: 1px solid #ef4444; border-radius: 4px; padding: 4px 6px; margin-bottom: 6px; color: #b91c1c; font-size: 9px; }
                .notes-title { font-weight: bold; margin-bottom: 2px; display: flex; align-items: center; gap: 3px; font-size: 8px; }
                
                .footer-meta {
                    margin-top: 10px; text-align: center; font-size: 7px; color: #94a3b8;
                    border-top: 1px dashed #cbd5e1; padding-top: 4px;
                    display: flex; justify-content: space-between;
                }
            `}</style>

            <PrintCopyBadge printNumber={printNumber} position="top-left" />

            <div className="header-section">
                <div className="company-info">
                    {logoUrl && <img src={logoUrl} alt="Logo" style={{ height: 60, marginBottom: 10 }} />}
                    <h1>{storeName}</h1>
                    {companyAddress && <p>{companyAddress}</p>}
                    {companyPhone && <p dir="ltr">{companyPhone}</p>}
                </div>
                <div className="doc-title">
                    <h2>{language === 'en' ? 'Delivery Note' : 'سند تسليم'}</h2>
                    <div className="ref-number tabular" dir="ltr">#{order.id.slice(-6).toUpperCase()}</div>
                </div>
            </div>

            <div className="info-grid">
                <div className="info-item">
                    <span className="info-label">التاريخ</span>
                    <span className="info-value tabular" dir="ltr">{new Date(order.createdAt).toLocaleDateString('en-GB')}</span>
                </div>
                <div className="info-item">
                    <span className="info-label">الوقت</span>
                    <span className="info-value tabular" dir="ltr">{new Date(order.createdAt).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' })}</span>
                </div>
                <div className="info-item">
                    <span className="info-label">اسم العميل</span>
                    <span className="info-value">{order.customerName}</span>
                </div>
                <div className="info-item">
                    <span className="info-label">رقم الهاتف</span>
                    <span className="info-value tabular" dir="ltr">{order.phoneNumber}</span>
                </div>
                {order.address && (
                    <div className="info-item" style={{ gridColumn: 'span 2' }}>
                        <span className="info-label">العنوان</span>
                        <span className="info-value">{order.address}</span>
                    </div>
                )}
                <div className="info-item">
                    <span className="info-label">الحالة</span>
                    <span className="info-value">{getStatusText(order.status)}</span>
                </div>
                {order.isScheduled && order.scheduledAt && (
                    <div className="info-item">
                        <span className="info-label">تاريخ الجدولة</span>
                        <span className="info-value tabular" dir="ltr" style={{ color: '#d97706' }}>{new Date(order.scheduledAt).toLocaleString('en-GB')}</span>
                    </div>
                )}
            </div>

            {order.notes && (
                <div className="notes-box">
                    <div className="notes-title">⚠️ ملاحظات خاصة (Special Notes)</div>
                    <div style={{ fontSize: 16, fontWeight: 'bold' }}>{order.notes}</div>
                </div>
            )}

            <h3 style={{ fontSize: 16, fontWeight: 'bold', marginBottom: 15, color: '#1E3A8A' }}>تفاصيل الأصناف</h3>
            <table className="lines-table">
                <thead>
                    <tr>
                        <th style={{ width: '10%', textAlign: 'center' }}>الكمية</th>
                        <th style={{ width: '60%' }}>الصنف</th>
                        <th style={{ width: '30%' }}>الإضافات</th>
                    </tr>
                </thead>
                <tbody>
                    {order.items.map((item, index) => (
                        <tr key={index}>
                            <td style={{ textAlign: 'center' }}>
                                <span className="qty-badge tabular">{item.quantity}</span>
                            </td>
                            <td style={{ fontWeight: 600, fontSize: 14 }}>
                                {item.name[language]}
                            </td>
                            <td>
                                {Object.values(item.selectedAddons).length > 0 ? (
                                    <div style={{ fontSize: 12, color: '#1D4ED8' }}>
                                        {Object.values(item.selectedAddons).map(({ addon, quantity }, i) => (
                                            <div key={i} style={{ marginBottom: 2 }}>
                                                <span style={{ color: '#16a34a', fontWeight: 'bold' }}>+</span>{' '}
                                                {quantity > 1 && <span className="tabular">{quantity}x </span>}
                                                {addon.name[language]}
                                            </div>
                                        ))}
                                    </div>
                                ) : (
                                    <span style={{ color: '#cbd5e1' }}>—</span>
                                )}
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>

            <DocumentAuditFooter
                audit={{ printedAt: new Date().toISOString(), generatedBy: companyName || 'AZTA ERP', ...(audit || {}) }}
                extraRight={<div>{companyName || 'AZTA ERP'}</div>}
            />
        </div>
    );
};

export default PrintableOrder;
