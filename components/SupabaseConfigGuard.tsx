import { useEffect, useRef } from 'react';
import { SUPABASE_CONFIG_ERROR_EVENT, isSupabaseConfigured } from '../supabase';
import { useToast } from '../contexts/ToastContext';
import { localizeError } from '../utils/errorUtils';

const extractSupabaseErrorText = (raw: unknown): string => {
  const txt = String(raw ?? '').trim();
  if (!txt) return '';
  try {
    const parsed = JSON.parse(txt);
    const msg = typeof parsed?.message === 'string' ? parsed.message : '';
    const hint = typeof parsed?.hint === 'string' ? parsed.hint : '';
    const details = typeof parsed?.details === 'string' ? parsed.details : '';
    return [msg, details, hint].map(s => String(s || '').trim()).filter(Boolean).join(' | ') || txt;
  } catch {
    return txt;
  }
};

export default function SupabaseConfigGuard() {
  const { showNotification } = useToast();
  const lastShownAtRef = useRef(0);

  useEffect(() => {
    if (typeof window === 'undefined') return;

    if (!isSupabaseConfigured()) {
      const now = Date.now();
      if (now - lastShownAtRef.current > 10_000) {
        lastShownAtRef.current = now;
        showNotification('مفتاح Supabase غير مضبوط (VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY). لن تعمل المزامنة أو تسجيل البيع حتى يتم ضبطه وإعادة النشر.', 'error', 12000);
      }
    }

    const handler = (evt: Event) => {
      const now = Date.now();
      if (now - lastShownAtRef.current < 5000) return;
      lastShownAtRef.current = now;
      const detail = (evt as CustomEvent<any>)?.detail;
      const raw = extractSupabaseErrorText(detail?.message);
      const localized = localizeError(raw);
      showNotification(localized || 'تعذر الاتصال بـ Supabase بسبب إعدادات ناقصة.', 'error', 12000);
    };

    window.addEventListener(SUPABASE_CONFIG_ERROR_EVENT, handler as any);
    return () => window.removeEventListener(SUPABASE_CONFIG_ERROR_EVENT, handler as any);
  }, [showNotification]);

  return null;
}

