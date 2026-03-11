export type DocumentAuditInfo = {
  printedAt?: string | null;
  printedBy?: string | null;
  generatedAt?: string | null;
  generatedBy?: string | null;
  createdAt?: string | null;
  createdBy?: string | null;
  approvedAt?: string | null;
  approvedBy?: string | null;
  postedAt?: string | null;
  postedBy?: string | null;
  deviceLabel?: string | null;
};

export const fmtDateTime = (iso?: string | null, locale: string = 'ar-EG-u-nu-latn') => {
  const v = String(iso || '').trim();
  if (!v) return null;
  try {
    return new Date(v).toLocaleString(locale);
  } catch {
    return v;
  }
};

export const safeShortId = (id?: string | null, take: number = 8) => {
  const v = String(id || '').trim();
  if (!v) return '';
  return v.replace(/-/g, '').slice(-take).toUpperCase();
};

export const buildAuditRows = (audit?: DocumentAuditInfo | null) => {
  const a = audit || {};
  const rows: Array<{ label: string; value: string }> = [];
  const push = (label: string, value: string | null) => {
    const v = String(value || '').trim();
    if (!v) return;
    rows.push({ label, value: v });
  };
  push('تاريخ الطباعة', fmtDateTime(a.printedAt) || null);
  push('طُبع بواسطة', a.printedBy || null);
  push('تاريخ الإنشاء', fmtDateTime(a.createdAt) || null);
  push('أُنشئ بواسطة', a.createdBy || null);
  push('تاريخ الاعتماد', fmtDateTime(a.approvedAt) || null);
  push('اعتماد بواسطة', a.approvedBy || null);
  push('تاريخ الترحيل', fmtDateTime(a.postedAt) || null);
  push('تُرحّل بواسطة', a.postedBy || null);
  push('الجهاز', a.deviceLabel || null);
  return rows;
};

