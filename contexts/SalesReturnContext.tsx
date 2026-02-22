import React, { createContext, useContext, useState, useEffect, useCallback } from 'react';
import { disableRealtime, getSupabaseClient, isRealtimeEnabled } from '../supabase';
import { localizeSupabaseError } from '../utils/errorUtils';
import { SalesReturn, SalesReturnItem, Order } from '../types';
import { useAuth } from './AuthContext';

interface SalesReturnContextType {
  returns: SalesReturn[];
  loading: boolean;
  createReturn: (order: Order, items: SalesReturnItem[], reason?: string, refundMethod?: 'cash' | 'network' | 'kuraimi') => Promise<SalesReturn>;
  processReturn: (returnId: string) => Promise<void>;
  getReturnsByOrder: (orderId: string) => Promise<SalesReturn[]>;
}

const SalesReturnContext = createContext<SalesReturnContextType | undefined>(undefined);

export const SalesReturnProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [returns, setReturns] = useState<SalesReturn[]>([]);
  const [loading, setLoading] = useState(false);
  const { user } = useAuth();
  const supabase = getSupabaseClient();

  const getCurrencyDecimalsByCode = (code: string) => {
    const c = String(code || '').toUpperCase();
    return c === 'YER' ? 0 : 2;
  };

  const roundMoneyByCode = (value: number, code: string) => {
    const n = Number(value);
    if (!Number.isFinite(n)) return 0;
    const dp = getCurrencyDecimalsByCode(code);
    const pow = Math.pow(10, dp);
    return Math.round(n * pow) / pow;
  };

  const mapRowToSalesReturn = (row: any): SalesReturn => {
    return {
      id: String(row?.id || ''),
      orderId: String(row?.order_id || row?.orderId || ''),
      returnDate: String(row?.return_date || row?.returnDate || ''),
      reason: typeof row?.reason === 'string' ? row.reason : undefined,
      refundMethod: (row?.refund_method || row?.refundMethod) as any,
      totalRefundAmount: Number(row?.total_refund_amount ?? row?.totalRefundAmount ?? 0) || 0,
      items: Array.isArray(row?.items) ? row.items : [],
      status: (row?.status || 'draft') as any,
      createdBy: typeof row?.created_by === 'string' ? row.created_by : (typeof row?.createdBy === 'string' ? row.createdBy : undefined),
      createdAt: String(row?.created_at || row?.createdAt || ''),
    };
  };

  const fetchReturns = useCallback(async () => {
    if (!user?.id || !supabase) return;
    try {
      setLoading(true);
      const { data, error } = await supabase
        .from('sales_returns')
        .select('*')
        .order('created_at', { ascending: false });

      if (error) throw error;
      setReturns((data || []).map(mapRowToSalesReturn));
    } catch (error) {
      console.error('Error fetching sales returns:', error);
    } finally {
      setLoading(false);
    }
  }, [supabase, user?.id]);

  useEffect(() => {
    fetchReturns();
  }, [fetchReturns]);

  useEffect(() => {
    if (!user?.id || !supabase) return;
    const scheduleRefetch = () => {
      if (typeof navigator !== 'undefined' && navigator.onLine === false) return;
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return;
      void fetchReturns();
    };

    const onFocus = () => scheduleRefetch();
    const onVisibility = () => scheduleRefetch();
    const onOnline = () => scheduleRefetch();
    if (typeof window !== 'undefined') {
      window.addEventListener('focus', onFocus);
      window.addEventListener('visibilitychange', onVisibility);
      window.addEventListener('online', onOnline);
    }

    if (!isRealtimeEnabled()) {
      return () => {
        if (typeof window !== 'undefined') {
          window.removeEventListener('focus', onFocus);
          window.removeEventListener('visibilitychange', onVisibility);
          window.removeEventListener('online', onOnline);
        }
      };
    }

    const channel = supabase
      .channel('public:sales_returns')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'sales_returns' }, () => {
        void fetchReturns();
      })
      .subscribe((status: any) => {
        if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
          disableRealtime();
          supabase.removeChannel(channel);
        }
      });
    return () => {
      if (typeof window !== 'undefined') {
        window.removeEventListener('focus', onFocus);
        window.removeEventListener('visibilitychange', onVisibility);
        window.removeEventListener('online', onOnline);
      }
      supabase.removeChannel(channel);
    };
  }, [fetchReturns, supabase, user?.id]);

  const createReturn = async (order: Order, items: SalesReturnItem[], reason?: string, refundMethod: 'cash' | 'network' | 'kuraimi' = 'cash') => {
    try {
      setLoading(true);
      const currency = String((order as any)?.currency || '').trim().toUpperCase() || 'YER';
      const itemsTotal = items.reduce((sum, item) => sum + (Number(item.total) || 0), 0);
      const deliveryFee = Number((order as any)?.deliveryFee ?? (order as any)?.delivery_fee ?? 0) || 0;
      const itemsTotalRounded = roundMoneyByCode(itemsTotal, currency);
      const deliveryFeeRounded = roundMoneyByCode(Math.max(0, deliveryFee), currency);
      const grossSubtotal = Number((order as any)?.subtotal ?? 0) || 0;
      const discountAmount = Number((order as any)?.discountAmount ?? (order as any)?.discount_amount ?? 0) || 0;
      const netSubtotal = Math.max(0, grossSubtotal - discountAmount);
      const netSubtotalRounded = roundMoneyByCode(netSubtotal, currency);
      const totalRefundAmount = Math.min(
        netSubtotalRounded,
        Math.max(0, itemsTotalRounded - deliveryFeeRounded)
      );

      const returnData = {
        order_id: order.id,
        return_date: new Date().toISOString(),
        reason,
        refund_method: refundMethod,
        total_refund_amount: totalRefundAmount,
        items: items, // JSONB
        status: 'draft',
        created_by: user?.id
      };

      const recentDraft = await (async () => {
        if (!supabase || !user?.id) return null;
        try {
          const { data, error } = await supabase
            .from('sales_returns')
            .select('*')
            .eq('order_id', order.id)
            .eq('status', 'draft')
            .eq('created_by', user.id)
            .order('created_at', { ascending: false })
            .limit(1)
            .maybeSingle();
          if (error) return null;
          return data || null;
        } catch {
          return null;
        }
      })();

      const { data, error } = recentDraft?.id
        ? await supabase!
          .from('sales_returns')
          .update({ ...returnData, updated_at: new Date().toISOString() } as any)
          .eq('id', recentDraft.id)
          .select()
          .single()
        : await supabase!
          .from('sales_returns')
          .insert([returnData])
          .select()
          .single();

      if (error) throw error;
      
      const mapped = mapRowToSalesReturn(data);
      setReturns(prev => {
        const next = prev.filter(r => r.id !== mapped.id);
        return [mapped, ...next];
      });
      return mapped;
    } catch (error) {
      console.error('Error creating sales return:', error);
      throw new Error(localizeSupabaseError(error));
    } finally {
      setLoading(false);
    }
  };

  const processReturn = async (returnId: string) => {
    try {
      setLoading(true);
      
      const attemptProcess = async () => {
        const { error } = await supabase!.rpc('process_sales_return', { p_return_id: returnId });
        if (error) throw error;
      };

      try {
        await attemptProcess();
      } catch (err: any) {
        const raw = String(err?.message || '');
        if (!/return amount exceeds order net subtotal/i.test(raw)) throw err;

        const { data: retRow, error: retErr } = await supabase!
          .from('sales_returns')
          .select('id,order_id,total_refund_amount,status')
          .eq('id', returnId)
          .maybeSingle();
        if (retErr) throw err;
        if (!retRow || String((retRow as any).status || '') !== 'draft') throw err;

        const orderId = String((retRow as any).order_id || '').trim();
        if (!orderId) throw err;

        const { data: orderRow, error: orderErr } = await supabase!
          .from('orders')
          .select('id,subtotal,discount,tax_amount,currency,data')
          .eq('id', orderId)
          .maybeSingle();
        if (orderErr || !orderRow) throw err;

        const currency = String((orderRow as any)?.currency || (orderRow as any)?.data?.currency || '').trim().toUpperCase() || 'YER';
        const grossSubtotal = Number((orderRow as any)?.data?.subtotal ?? (orderRow as any)?.subtotal ?? 0) || 0;
        const discountAmount = Number((orderRow as any)?.data?.discountAmount ?? (orderRow as any)?.discount ?? 0) || 0;
        const netSubtotalRounded = roundMoneyByCode(Math.max(0, grossSubtotal - discountAmount), currency);
        const existing = roundMoneyByCode(Number((retRow as any)?.total_refund_amount ?? 0) || 0, currency);
        const corrected = Math.min(existing, netSubtotalRounded);

        const { error: updErr } = await supabase!
          .from('sales_returns')
          .update({ total_refund_amount: corrected, updated_at: new Date().toISOString() } as any)
          .eq('id', returnId)
          .eq('status', 'draft');
        if (updErr) throw err;

        await attemptProcess();
      }

      // Update local state
      setReturns(prev => 
        prev.map(r => r.id === returnId ? { ...r, status: 'completed' } : r)
      );

    } catch (error) {
      console.error('Error processing sales return:', error);
      throw new Error(localizeSupabaseError(error));
    } finally {
      setLoading(false);
    }
  };

  const getReturnsByOrder = async (orderId: string) => {
    if (!supabase) return [];
    const { data, error } = await supabase
      .from('sales_returns')
      .select('*')
      .eq('order_id', orderId);
      
    if (error) {
        console.error("Error fetching returns for order:", error);
        return [];
    }
    return (data || []).map(mapRowToSalesReturn);
  };

  return (
    <SalesReturnContext.Provider value={{
      returns,
      loading,
      createReturn,
      processReturn,
      getReturnsByOrder
    }}>
      {children}
    </SalesReturnContext.Provider>
  );
};

export const useSalesReturn = () => {
  const context = useContext(SalesReturnContext);
  if (context === undefined) {
    throw new Error('useSalesReturn must be used within a SalesReturnProvider');
  }
  return context;
};
