import React from 'react';

/**
 * BatchLabel — Printable batch label with QR code containing GS1-style data.
 * Encodes: itemId, batch code, production date, expiry date, quantity.
 *
 * The QR code encodes a GS1 AI-style string:
 *   (01) GTIN/itemId  (11) production_date  (17) expiry_date  (10) batch_code
 *
 * Usage:
 *   <BatchLabel
 *     itemName="حليب طازج"
 *     batchCode="BATCH-001"
 *     productionDate="2026-01-15"
 *     expiryDate="2026-03-15"
 *     quantity={100}
 *     warehouseName="المستودع الرئيسي"
 *   />
 */

export interface BatchLabelProps {
    itemName: string;
    batchCode?: string;
    productionDate?: string;
    expiryDate?: string;
    quantity?: number;
    unitLabel?: string;
    warehouseName?: string;
    barcode?: string;
}

/** Format date as YYMMDD (GS1 standard) */
const toGS1Date = (dateStr?: string): string => {
    if (!dateStr) return '000000';
    const d = new Date(dateStr);
    if (isNaN(d.getTime())) return '000000';
    const yy = String(d.getFullYear()).slice(-2);
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    const dd = String(d.getDate()).padStart(2, '0');
    return `${yy}${mm}${dd}`;
};

/** Build GS1-128 style data string with Application Identifiers */
const buildGS1Data = (props: BatchLabelProps): string => {
    const parts: string[] = [];
    // AI 01: GTIN (we use barcode or item identifier)
    if (props.barcode) parts.push(`(01)${props.barcode.padStart(14, '0').slice(0, 14)}`);
    // AI 11: Production date
    if (props.productionDate) parts.push(`(11)${toGS1Date(props.productionDate)}`);
    // AI 17: Expiry date
    if (props.expiryDate) parts.push(`(17)${toGS1Date(props.expiryDate)}`);
    // AI 10: Batch/Lot number
    if (props.batchCode) parts.push(`(10)${props.batchCode.slice(0, 20)}`);
    // AI 37: Quantity
    if (props.quantity && props.quantity > 0) parts.push(`(37)${String(Math.round(props.quantity))}`);
    return parts.join('');
};

/** Generate a simple QR code SVG using a basic encoding (for print) */
const QRCodeSVG: React.FC<{ data: string; size?: number }> = ({ data, size = 120 }) => {
    // We use a simple approach: encode the data as a data URI for an SVG-based QR image
    // In production, you'd use a library like `qrcode` — here we use a CSS/HTML data matrix fallback
    const encodedData = encodeURIComponent(data);
    const qrApiUrl = `https://api.qrserver.com/v1/create-qr-code/?size=${size}x${size}&data=${encodedData}&format=svg`;

    return (
        <img
            src={qrApiUrl}
            alt="QR Code"
            width={size}
            height={size}
            style={{ imageRendering: 'pixelated' }}
            crossOrigin="anonymous"
        />
    );
};

const formatDisplayDate = (dateStr?: string): string => {
    if (!dateStr) return '—';
    const d = new Date(dateStr);
    if (isNaN(d.getTime())) return dateStr;
    return d.toLocaleDateString('ar-SA-u-nu-latn', { year: 'numeric', month: '2-digit', day: '2-digit' });
};

const BatchLabel: React.FC<BatchLabelProps> = (props) => {
    const gs1Data = buildGS1Data(props);

    return (
        <div
            className="batch-label"
            style={{
                width: '80mm',
                padding: '4mm',
                border: '1px solid #333',
                fontFamily: 'Arial, sans-serif',
                fontSize: '10pt',
                direction: 'rtl',
                background: '#fff',
                color: '#000',
                pageBreakInside: 'avoid',
            }}
        >
            {/* Header */}
            <div style={{ textAlign: 'center', fontWeight: 'bold', fontSize: '12pt', marginBottom: '2mm', borderBottom: '1px solid #999', paddingBottom: '2mm' }}>
                {props.itemName}
            </div>

            {/* Body - 2 columns: info + QR */}
            <div style={{ display: 'flex', gap: '3mm', alignItems: 'flex-start' }}>
                {/* Left: Details */}
                <div style={{ flex: 1, lineHeight: '1.6' }}>
                    {props.batchCode && (
                        <div><strong>الدفعة:</strong> <span style={{ fontFamily: 'monospace' }}>{props.batchCode}</span></div>
                    )}
                    {props.productionDate && (
                        <div><strong>ت. الإنتاج:</strong> {formatDisplayDate(props.productionDate)}</div>
                    )}
                    {props.expiryDate && (
                        <div style={{ color: '#c00', fontWeight: 'bold' }}><strong>ت. الانتهاء:</strong> {formatDisplayDate(props.expiryDate)}</div>
                    )}
                    {props.quantity != null && props.quantity > 0 && (
                        <div><strong>الكمية:</strong> {props.quantity} {props.unitLabel || ''}</div>
                    )}
                    {props.warehouseName && (
                        <div><strong>المستودع:</strong> {props.warehouseName}</div>
                    )}
                </div>

                {/* Right: QR Code */}
                <div style={{ flexShrink: 0, textAlign: 'center' }}>
                    <QRCodeSVG data={gs1Data} size={80} />
                    <div style={{ fontSize: '6pt', color: '#666', marginTop: '1mm' }}>GS1</div>
                </div>
            </div>

            {/* Footer - human-readable GS1 data */}
            <div style={{ marginTop: '2mm', borderTop: '1px solid #ccc', paddingTop: '1mm', fontSize: '7pt', fontFamily: 'monospace', direction: 'ltr', textAlign: 'center', color: '#555', wordBreak: 'break-all' }}>
                {gs1Data}
            </div>
        </div>
    );
};

export default BatchLabel;
