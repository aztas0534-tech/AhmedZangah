import { getSupabaseClient } from '../supabase';

/**
 * Currency decimal places cache.
 * Loaded from DB `currencies.decimal_places` once and cached in memory.
 * Supports KWD(3), JPY(0), YER(0), USD(2), etc.
 */

const _cache: Record<string, number> = {};
let _loaded = false;
let _loading: Promise<void> | null = null;

const KNOWN_DEFAULTS: Record<string, number> = {
    YER: 0, JPY: 0, KRW: 0, VND: 0,
    KWD: 3, BHD: 3, OMR: 3,
};

async function loadDecimalPlaces(): Promise<void> {
    if (_loaded) return;
    if (_loading) return _loading;
    _loading = (async () => {
        try {
            const supabase = getSupabaseClient();
            if (!supabase) return;
            const { data, error } = await supabase
                .from('currencies')
                .select('code,decimal_places');
            if (error) throw error;
            if (Array.isArray(data)) {
                for (const row of data) {
                    const code = String(row.code || '').trim().toUpperCase();
                    if (code) _cache[code] = Number(row.decimal_places ?? 2);
                }
            }
            _loaded = true;
        } catch {
            // silent — will use defaults
        } finally {
            _loading = null;
        }
    })();
    return _loading;
}

/**
 * Get the number of decimal places for a currency code.
 * Uses cached value from DB, falls back to KNOWN_DEFAULTS then to 2.
 */
export function getCurrencyDecimalsByCode(code: string): number {
    const c = String(code || '').trim().toUpperCase();
    if (!c) return 2;
    if (c in _cache) return _cache[c];
    if (c in KNOWN_DEFAULTS) return KNOWN_DEFAULTS[c];
    return 2;
}

/**
 * Initialize the currency decimals cache from the database.
 * Call this early in app startup (e.g., in useEffect of root component).
 * Safe to call multiple times — subsequent calls are no-ops.
 */
export async function initCurrencyDecimals(): Promise<void> {
    await loadDecimalPlaces();
}

/**
 * Format a money value with the correct number of decimals for the given currency.
 */
export function formatMoneyByCode(value: number, code: string): string {
    const n = Number(value);
    const dp = getCurrencyDecimalsByCode(code);
    const v = Number.isFinite(n) ? n : 0;
    try {
        return v.toLocaleString('ar-EG-u-nu-latn', { minimumFractionDigits: dp, maximumFractionDigits: dp });
    } catch {
        return v.toFixed(dp);
    }
}

/**
 * Round a money value to the correct number of decimals for the given currency.
 */
export function roundMoneyByCode(value: number, code: string): number {
    const n = Number(value);
    if (!Number.isFinite(n)) return 0;
    const dp = getCurrencyDecimalsByCode(code);
    const pow = Math.pow(10, dp);
    return Math.round(n * pow) / pow;
}
