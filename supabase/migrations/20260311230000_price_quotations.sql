-- Migration: نظام عروض الأسعار (Price Quotations)
-- التاريخ: 2026-03-11
-- الوصف: نظام كامل لإنشاء وإدارة عروض الأسعار للعملاء والموزعين

-- ==========================================
-- 1. تسلسل أرقام عروض الأسعار
-- ==========================================
CREATE SEQUENCE IF NOT EXISTS public.quotation_number_seq START 1;

-- ==========================================
-- 2. جدول عروض الأسعار (ترويسة)
-- ==========================================
CREATE TABLE IF NOT EXISTS public.price_quotations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_number TEXT NOT NULL UNIQUE DEFAULT ('QT-' || LPAD(nextval('public.quotation_number_seq')::TEXT, 5, '0')),
  customer_name TEXT NOT NULL DEFAULT '',
  customer_phone TEXT DEFAULT '',
  customer_company TEXT DEFAULT '',
  customer_address TEXT DEFAULT '',
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','sent','accepted','expired','cancelled')),
  valid_until DATE DEFAULT (CURRENT_DATE + INTERVAL '15 days'),
  currency TEXT DEFAULT 'YER',
  discount_type TEXT DEFAULT 'none' CHECK (discount_type IN ('none','percentage','fixed')),
  discount_value NUMERIC NOT NULL DEFAULT 0 CHECK (discount_value >= 0),
  subtotal NUMERIC NOT NULL DEFAULT 0,
  discount_amount NUMERIC NOT NULL DEFAULT 0,
  tax_rate NUMERIC NOT NULL DEFAULT 0 CHECK (tax_rate >= 0 AND tax_rate <= 100),
  tax_amount NUMERIC NOT NULL DEFAULT 0,
  total NUMERIC NOT NULL DEFAULT 0,
  notes TEXT DEFAULT '',
  terms TEXT DEFAULT '',
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Trigger تحديث updated_at
DROP TRIGGER IF EXISTS trg_price_quotations_updated_at ON public.price_quotations;
CREATE TRIGGER trg_price_quotations_updated_at
  BEFORE UPDATE ON public.price_quotations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- الفهارس
CREATE INDEX IF NOT EXISTS idx_price_quotations_status ON public.price_quotations(status);
CREATE INDEX IF NOT EXISTS idx_price_quotations_created ON public.price_quotations(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_price_quotations_customer ON public.price_quotations(customer_name);
CREATE INDEX IF NOT EXISTS idx_price_quotations_valid_until ON public.price_quotations(valid_until);

-- ==========================================
-- 3. جدول بنود عروض الأسعار
-- ==========================================
CREATE TABLE IF NOT EXISTS public.price_quotation_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id UUID NOT NULL REFERENCES public.price_quotations(id) ON DELETE CASCADE,
  item_id TEXT REFERENCES public.menu_items(id) ON DELETE SET NULL,
  item_name TEXT NOT NULL DEFAULT '',
  unit TEXT DEFAULT 'piece',
  quantity NUMERIC NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price NUMERIC NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
  total NUMERIC NOT NULL DEFAULT 0,
  notes TEXT DEFAULT '',
  sort_order INT NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_quotation_items_quotation ON public.price_quotation_items(quotation_id);
CREATE INDEX IF NOT EXISTS idx_quotation_items_item ON public.price_quotation_items(item_id);

-- ==========================================
-- 4. RLS
-- ==========================================
ALTER TABLE public.price_quotations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.price_quotation_items ENABLE ROW LEVEL SECURITY;

-- القراءة: المشرفون فقط
DROP POLICY IF EXISTS price_quotations_select ON public.price_quotations;
CREATE POLICY price_quotations_select ON public.price_quotations
  FOR SELECT USING (public.is_admin());

DROP POLICY IF EXISTS price_quotations_write ON public.price_quotations;
CREATE POLICY price_quotations_write ON public.price_quotations
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS price_quotation_items_select ON public.price_quotation_items;
CREATE POLICY price_quotation_items_select ON public.price_quotation_items
  FOR SELECT USING (public.is_admin());

DROP POLICY IF EXISTS price_quotation_items_write ON public.price_quotation_items;
CREATE POLICY price_quotation_items_write ON public.price_quotation_items
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

NOTIFY pgrst, 'reload schema';
