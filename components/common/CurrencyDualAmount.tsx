import React, { useMemo } from 'react';

type Props = {
  amount: number;
  currencyCode?: string;
  baseAmount?: number;
  fxRate?: number;
  baseCurrencyCode?: string;
  label?: string;
  compact?: boolean;
};

const fmt = (n: number, decimals: number) => {
  const v = Number(n || 0);
  const dp = Number.isFinite(decimals) ? Math.max(0, Math.min(6, Math.trunc(decimals))) : 2;
  try {
    return v.toLocaleString('ar-EG-u-nu-latn', { minimumFractionDigits: dp, maximumFractionDigits: dp });
  } catch {
    return v.toFixed(dp);
  }
};

const CurrencyDualAmount: React.FC<Props> = ({ amount, currencyCode, baseAmount, fxRate, baseCurrencyCode, label, compact }) => {
  const code = useMemo(() => String(currencyCode || '').toUpperCase(), [currencyCode]);
  const decimals = code === 'YER' ? 0 : 2;
  const symbolMap: Record<string, string> = {
    SAR: '﷼',
    YER: '﷼',
    USD: '$',
    EUR: '€',
    GBP: '£',
    AED: 'د.إ',
    KWD: 'د.ك',
    BHD: 'د.ب',
    OMR: 'ر.ع.',
    QAR: 'ر.ق',
  };
  const sym = symbolMap[code] || code || '—';
  const displayCode = (code === 'SAR' || code === 'YER') ? code : sym;
  const baseCode = String(baseCurrencyCode || '').toUpperCase();
  const baseDecimals = baseCode === 'YER' ? 0 : 2;
  const hasBase = typeof baseAmount === 'number' && Number.isFinite(baseAmount as number) && (baseAmount as number) !== 0 && typeof fxRate === 'number' && Number(fxRate) > 0;

  return (
    <div className={compact ? '' : 'space-y-0.5'}>
      <div className={compact ? 'text-sm font-bold' : 'text-base font-bold'}>
        {label ? <span className="text-gray-600 dark:text-gray-300 mr-1">{label}:</span> : null}
        <span dir="ltr">{fmt(amount, decimals)} <span className="text-xs">{displayCode}</span></span>
      </div>
      {hasBase ? (
        <div className="text-[11px] text-gray-600 dark:text-gray-400" dir="ltr">
          ≈ {fmt(Number(baseAmount), baseDecimals)} <span className="text-[10px]">{baseCode || '—'}</span> • FX={Number(fxRate).toFixed(6)}
        </div>
      ) : null}
    </div>
  );
};

export default CurrencyDualAmount;
