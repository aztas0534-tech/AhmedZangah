import React, { useRef, useEffect, useMemo, useState } from 'react';

interface NumberInputProps {
    id: string;
    name: string;
    value: number;
    onChange: (e: React.ChangeEvent<HTMLInputElement>) => void;
    min?: number;
    max?: number;
    step?: number;
    placeholder?: string;
    disabled?: boolean;
    label?: string;
    className?: string;
}

const NumberInput: React.FC<NumberInputProps> = ({
    id,
    name,
    value,
    onChange,
    min = 0,
    max,
    step = 1,
    placeholder,
    disabled,
    className = '',
}) => {
    const inputRef = useRef<HTMLInputElement>(null);
    const [isFocused, setIsFocused] = useState(false);
    const [draft, setDraft] = useState<string>(() => {
        const n = Number(value);
        return Number.isFinite(n) ? String(n) : '0';
    });

    const normalizeDraft = useMemo(() => {
        const arabicIndic: Record<string, string> = { '٠': '0', '١': '1', '٢': '2', '٣': '3', '٤': '4', '٥': '5', '٦': '6', '٧': '7', '٨': '8', '٩': '9' };
        const easternArabicIndic: Record<string, string> = { '۰': '0', '۱': '1', '۲': '2', '۳': '3', '۴': '4', '۵': '5', '۶': '6', '۷': '7', '۸': '8', '۹': '9' };
        return (raw: string) => {
            let s = String(raw ?? '');
            s = s.replace(/[٠-٩]/g, (d) => arabicIndic[d] || d);
            s = s.replace(/[۰-۹]/g, (d) => easternArabicIndic[d] || d);
            s = s.replace(/٫/g, '.').replace(/,/g, '.');

            const keepTrailingDot = s.trim().endsWith('.');
            const isNeg = s.trim().startsWith('-');

            s = s.replace(/[^\d.]/g, '');
            const parts = s.split('.');
            const intPart = parts[0] || '';
            const fracPart = parts.slice(1).join('');
            if (!intPart && !fracPart) return keepTrailingDot ? (isNeg ? '-.' : '.') : (isNeg ? '-' : '');
            const core = fracPart ? `${intPart}.${fracPart}` : intPart;
            const withDot = keepTrailingDot && !core.includes('.') ? `${core}.` : core;
            return isNeg ? (withDot.startsWith('-') ? withDot : `-${withDot}`) : withDot;
        };
    }, []);

    useEffect(() => {
        if (isFocused) return;
        const n = Number(value);
        setDraft(Number.isFinite(n) ? String(n) : '0');
    }, [isFocused, value]);

    // Prevent scroll wheel from changing number
    useEffect(() => {
        const handleWheel = (e: WheelEvent) => {
            if (document.activeElement === inputRef.current) {
                e.preventDefault();
            }
        };
        const currentInput = inputRef.current;
        if (currentInput) {
            currentInput.addEventListener('wheel', handleWheel, { passive: false });
        }
        return () => {
            if (currentInput) {
                currentInput.removeEventListener('wheel', handleWheel);
            }
        };
    }, []);

    const handleIncrement = () => {
        if (disabled) return;
        const currentValue = Number(value) || 0;
        const newValue = currentValue + step;
        if (max !== undefined && newValue > max) return;

        // Create a synthetic event
        const event = {
            target: {
                name,
                value: Number.isInteger(step) ? newValue.toString() : newValue.toFixed(4), // Precision handling
                type: 'number',
            },
        } as unknown as React.ChangeEvent<HTMLInputElement>;

        onChange(event);
        if (isFocused) {
            setDraft(Number.isInteger(step) ? newValue.toString() : newValue.toFixed(4));
        }
    };

    const handleDecrement = () => {
        if (disabled) return;
        const currentValue = Number(value) || 0;
        const newValue = currentValue - step;
        if (min !== undefined && newValue < min) return;

        // Create a synthetic event
        const event = {
            target: {
                name,
                value: Number.isInteger(step) ? newValue.toString() : newValue.toFixed(4),
                type: 'number',
            },
        } as unknown as React.ChangeEvent<HTMLInputElement>;

        onChange(event);
        if (isFocused) {
            setDraft(Number.isInteger(step) ? newValue.toString() : newValue.toFixed(4));
        }
    };

    return (
        <div className={`flex items-center rounded-lg border border-gray-300 dark:border-gray-600 bg-gray-50 dark:bg-gray-700 overflow-hidden focus-within:ring-2 focus-within:ring-gold-500 focus-within:border-gold-500 transition shadow-sm ${className}`}>
            <button
                type="button"
                onClick={handleDecrement}
                disabled={disabled || (min !== undefined && value <= min)}
                className="w-12 h-12 flex items-center justify-center bg-gray-100 dark:bg-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-500 disabled:opacity-50 disabled:cursor-not-allowed border-l border-gray-200 dark:border-gray-500 rtl:border-l-0 rtl:border-r transition active:bg-gray-300 dark:active:bg-gray-400 touch-manipulation"
                aria-label="Decrease"
            >
                <svg xmlns="http://www.w3.org/2000/svg" className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M20 12H4" />
                </svg>
            </button>

            <input
                ref={inputRef}
                id={id}
                name={name}
                type="text"
                inputMode="decimal"
                value={draft}
                onFocus={() => setIsFocused(true)}
                onBlur={() => {
                    setIsFocused(false);
                    const normalized = normalizeDraft(draft);
                    const fixed = normalized.endsWith('.') ? normalized.slice(0, -1) : normalized;
                    const parsed = Number(fixed);
                    let nextNum = Number.isFinite(parsed) ? parsed : 0;
                    if (min !== undefined && nextNum < min) nextNum = min;
                    if (max !== undefined && nextNum > max) nextNum = max;
                    const nextStr = Number.isInteger(step) ? String(Math.round(nextNum)) : String(nextNum);
                    setDraft(nextStr);
                    const evt = {
                        target: {
                            name,
                            value: nextStr,
                            type: 'text',
                        },
                    } as unknown as React.ChangeEvent<HTMLInputElement>;
                    onChange(evt);
                }}
                onChange={(e) => {
                    const normalized = normalizeDraft(e.target.value);
                    setDraft(normalized);
                    const evt = {
                        target: {
                            name,
                            value: normalized,
                            type: 'text',
                        },
                    } as unknown as React.ChangeEvent<HTMLInputElement>;
                    onChange(evt);
                }}
                placeholder={placeholder}
                disabled={disabled}
                className="w-full h-12 p-2 text-center bg-transparent border-none focus:ring-0 text-gray-900 dark:text-white font-bold text-lg appearance-none"
                style={{ MozAppearance: 'textfield' }} // Hide spinner in Firefox
            />

            <button
                type="button"
                onClick={handleIncrement}
                disabled={disabled || (max !== undefined && value >= max)}
                className="w-12 h-12 flex items-center justify-center bg-gray-100 dark:bg-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-500 disabled:opacity-50 disabled:cursor-not-allowed border-r border-gray-200 dark:border-gray-500 rtl:border-r-0 rtl:border-l transition active:bg-gray-300 dark:active:bg-gray-400 touch-manipulation"
                aria-label="Increase"
            >
                <svg xmlns="http://www.w3.org/2000/svg" className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M12 4v16m8-8H4" />
                </svg>
            </button>
        </div>
    );
};

export default NumberInput;
