import React, { createContext, useContext, useMemo } from 'react';
import { useAuth } from './AuthContext';

type GuardResult = { ok: boolean; reason?: string };

type GovernanceContextType = {
  canChangeWarehouse: (input: { hasItems: boolean; hasSnapshot: boolean }) => GuardResult;
  canChangeCurrency: (input: { hasItems: boolean; invoiceIssued: boolean }) => GuardResult;
  guardPosting: () => GuardResult;
};

const GovernanceContext = createContext<GovernanceContextType | undefined>(undefined);

export const GovernanceProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { hasPermission } = useAuth();

  const canChangeWarehouse = (input: { hasItems: boolean; hasSnapshot: boolean }): GuardResult => {
    if (input.hasSnapshot) return { ok: false, reason: 'لا يمكن تغيير المستودع بعد إصدار الفاتورة.' };
    if (input.hasItems) return { ok: false, reason: 'لا يمكن تغيير المستودع بعد إضافة أصناف.' };
    return { ok: true };
  };

  const canChangeCurrency = (input: { hasItems: boolean; invoiceIssued: boolean }): GuardResult => {
    if (input.invoiceIssued) return { ok: false, reason: 'لا يمكن تغيير العملة بعد إصدار الفاتورة.' };
    if (input.hasItems) return { ok: false, reason: 'لا يمكن تغيير العملة بعد إضافة أصناف.' };
    return { ok: true };
  };

  const guardPosting = (): GuardResult => {
    const ok = hasPermission('accounting.manage');
    return ok ? { ok: true } : { ok: false, reason: 'ليس لديك صلاحية الترحيل.' };
  };

  const value = useMemo<GovernanceContextType>(() => ({
    canChangeWarehouse,
    canChangeCurrency,
    guardPosting,
  }), []);

  return (
    <GovernanceContext.Provider value={value}>
      {children}
    </GovernanceContext.Provider>
  );
};

export const useGovernance = () => {
  const ctx = useContext(GovernanceContext);
  if (!ctx) {
    return {
      canChangeWarehouse: () => ({ ok: true }),
      canChangeCurrency: () => ({ ok: true }),
      guardPosting: () => ({ ok: false, reason: 'GovernanceProvider غير مُفعّل.' }),
    } as GovernanceContextType;
  }
  return ctx;
};
