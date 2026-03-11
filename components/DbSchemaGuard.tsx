import { useEffect, useRef } from 'react';
import { useAuth } from '../contexts/AuthContext';
import { useToast } from '../contexts/ToastContext';
import { getSupabaseClient } from '../supabase';
import { localizeSupabaseError } from '../utils/errorUtils';

type HealthcheckResult = {
  ok?: boolean;
  appliedVersion?: string;
  missing?: string[];
};

export default function DbSchemaGuard() {
  const { isAuthenticated, user, hasPermission } = useAuth();
  const { showNotification } = useToast();
  const ranRef = useRef(false);

  useEffect(() => {
    if (!isAuthenticated || !user) return;
    if (ranRef.current) return;
    ranRef.current = true;

    const shouldCheck =
      user.role === 'owner' ||
      user.role === 'manager' ||
      hasPermission('accounting.manage') ||
      hasPermission('orders.updateStatus.all');
    if (!shouldCheck) return;

    const supabase = getSupabaseClient();
    if (!supabase) return;

    (async () => {
      try {
        const { data, error } = await supabase.rpc('app_schema_healthcheck');
        if (error) {
          const code = String((error as any)?.code || '');
          const msg = String((error as any)?.message || '');
          if (code === '42883' || /could not find the function/i.test(msg)) {
            showNotification('قاعدة البيانات غير محدثة: فحص التوافق غير متوفر. طبّق ترحيلات Supabase ثم أعد المحاولة.', 'error', 8000);
            return;
          }
          const localized = localizeSupabaseError(error) || msg;
          if (localized && /not allowed/i.test(localized)) return;
          showNotification(`فشل فحص توافق قاعدة البيانات: ${localized || 'خطأ غير معروف'}`, 'error', 8000);
          return;
        }

        const res = (data || {}) as HealthcheckResult;
        const ok = Boolean(res.ok);
        if (ok) return;

        const missing = Array.isArray(res.missing) ? res.missing : [];
        const shown = missing.slice(0, 4).join('، ');
        const more = missing.length > 4 ? ` (+${missing.length - 4})` : '';
        const ver = String(res.appliedVersion || '').trim();
        const suffix = ver ? ` (آخر ترحيل مطبق: ${ver})` : '';
        showNotification(`قاعدة البيانات تحتاج تحديثات لتتوافق مع الواجهة: ${shown}${more}${suffix}`, 'error', 12000);
      } catch (e: any) {
        const msg = String(e?.message || 'تعذر فحص توافق قاعدة البيانات');
        showNotification(msg, 'error', 8000);
      }
    })();
  }, [hasPermission, isAuthenticated, showNotification, user]);

  return null;
}

