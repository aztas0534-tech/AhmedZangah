const tokenize = (value: string): string[] => {
  return String(value || '')
    .trim()
    .toUpperCase()
    .split(/[^A-Z0-9\u0600-\u06FF]+/)
    .filter(Boolean);
};

export const inferDestinationParentCode = (code: string, parentCode?: string): '1020' | '1030' | undefined => {
  const normalizedParent = String(parentCode || '').trim();
  if (normalizedParent === '1020' || normalizedParent === '1030') return normalizedParent;
  const tokens = tokenize(code);
  if (tokens.includes('1020')) return '1020';
  if (tokens.includes('1030')) return '1030';
  return undefined;
};

const detectCurrencyToken = (code: string, name: string): 'YER' | 'SAR' | 'USD' | '' => {
  const codeTokens = tokenize(code);
  if (codeTokens.includes('YER')) return 'YER';
  if (codeTokens.includes('SAR')) return 'SAR';
  if (codeTokens.includes('USD')) return 'USD';
  const raw = `${String(name || '')} ${String(code || '')}`.toLowerCase();
  if (/(ريال يمني|يمني|yer)/i.test(raw)) return 'YER';
  if (/(ريال سعودي|سعودي|sar)/i.test(raw)) return 'SAR';
  if (/(دولار|usd)/i.test(raw)) return 'USD';
  return '';
};

export const matchesDestinationCurrency = (code: string, name: string, currency: string): boolean => {
  const curr = String(currency || '').trim().toUpperCase();
  if (!curr) return true;
  const detected = detectCurrencyToken(code, name);
  if (!detected) return true;
  return detected === curr;
};
