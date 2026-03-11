import React from 'react';

/**
 * Reusable print copy badge for any printable document.
 * Shows "أصل / ORIGINAL" (green) for first print,
 * "نسخة #N / COPY #N" (amber) for subsequent prints.
 */

type PrintCopyBadgeProps = {
  printNumber?: number | null;
  position?: 'top-left' | 'top-right';
};

const PrintCopyBadge: React.FC<PrintCopyBadgeProps> = ({ printNumber, position = 'top-left' }) => {
  const pn = Number(printNumber) || 0;
  if (pn <= 0) return null;

  const isOriginal = pn <= 1;
  const label = isOriginal ? 'أصل / ORIGINAL' : `نسخة #${pn} / COPY #${pn}`;
  const posStyle = position === 'top-right' ? { top: 4, right: 8 } : { top: 4, left: 8 };

  return (
    <>
      <style>{`
        @media print {
          .pcb-badge {
            display: inline-block !important;
            padding: 1px 8px !important;
            border-radius: 2px !important;
            font-size: 7px !important;
            font-weight: 800 !important;
            letter-spacing: 0.5px !important;
            text-transform: uppercase !important;
            border: 1pt solid !important;
            z-index: 9999 !important;
          }
          .pcb-original {
            background: #ECFDF5 !important;
            color: #065F46 !important;
            border-color: #059669 !important;
          }
          .pcb-copy {
            background: #FFFBEB !important;
            color: #92400E !important;
            border-color: #D97706 !important;
          }
        }
        .pcb-badge {
          display: inline-block;
          padding: 2px 12px;
          border-radius: 3px;
          font-size: 10px;
          font-weight: 800;
          letter-spacing: 1px;
          text-transform: uppercase;
          border: 1px solid;
          z-index: 9999;
        }
        .pcb-original {
          background: #ECFDF5;
          color: #065F46;
          border-color: #059669;
        }
        .pcb-copy {
          background: #FFFBEB;
          color: #92400E;
          border-color: #D97706;
        }
      `}</style>
      <div style={{ position: 'absolute', ...posStyle, zIndex: 9999 }}>
        <span className={`pcb-badge ${isOriginal ? 'pcb-original' : 'pcb-copy'}`}>
          {label}
        </span>
      </div>
    </>
  );
};

export default PrintCopyBadge;
