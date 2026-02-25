import React from 'react';
import { buildAuditRows, DocumentAuditInfo } from '../../../utils/documentStandards';

export default function DocumentAuditFooter(props: { audit?: DocumentAuditInfo | null; extraLeft?: React.ReactNode; extraRight?: React.ReactNode }) {
  const rows = buildAuditRows(props.audit);
  if (!rows.length && !props.extraLeft && !props.extraRight) return null;

  return (
    <div style={{ marginTop: 24, borderTop: '1px dashed #cbd5e1', paddingTop: 10, display: 'flex', justifyContent: 'space-between', gap: 12, fontSize: 10, color: '#64748b' }}>
      <div style={{ flex: 1 }}>
        {props.extraLeft}
        {rows.length ? (
          <div style={{ display: 'grid', gridTemplateColumns: '140px 1fr', columnGap: 10, rowGap: 4 }}>
            {rows.map((r, idx) => (
              <React.Fragment key={idx}>
                <div style={{ fontWeight: 700 }}>{r.label}</div>
                <div style={{ fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, \"Liberation Mono\", \"Courier New\", monospace' }}>{r.value}</div>
              </React.Fragment>
            ))}
          </div>
        ) : null}
      </div>
      <div style={{ textAlign: 'left' }}>
        {props.extraRight}
      </div>
    </div>
  );
}

