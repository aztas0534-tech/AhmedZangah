export const translateAccountName = (name: string): string => {
    const n = name.trim().toLowerCase();

    // Specific known system accounts
    if (n === 'cash') return 'الصندوق (نقداً)';
    if (n === 'bank') return 'البنك';
    if (n === 'accounts receivable') return 'الذمم المدينة (العملاء)';
    if (n === 'accounts payable') return 'الذمم الدائنة (الموردين)';
    if (n === 'inventory') return 'المخزون';
    if (n === 'vat recoverable') return 'ضريبة القيمة المضافة المستردة';
    if (n === 'vat payable') return 'ضريبة القيمة المضافة المستحقة';
    if (n === 'customer deposits') return 'عربون / تأمينات العملاء';
    if (n === 'retained earnings') return 'الأرباح المبقاة';
    if (n === 'sales revenue') return 'إيرادات المبيعات';
    if (n === 'delivery income' || n === 'delivery revenue') return 'إيرادات التوصيل';
    if (n === 'inventory gain') return 'أرباح المخزون (زيادة)';
    if (n === 'sales discounts' || n === 'sales discount') return 'خصومات المبيعات';
    if (n === 'sales returns') return 'مردودات المبيعات';
    if (n === 'purchase returns') return 'مردودات المشتريات';
    if (n === 'cost of goods sold' || n === 'cost of sales') return 'تكلفة البضاعة المباعة';
    if (n === 'inventory shrinkage' || n === 'inventory adjustment') return 'عجز / تسويات المخزون';
    if (n === 'operating expenses') return 'المصروفات التشغيلية';
    if (n === 'cash over/short' || n === 'cash shift discrepancy') return 'عجز/زيادة الصندوق';
    if (n === 'salary expense') return 'مصروفات الرواتب';
    if (n === 'rent expense') return 'مصروفات الإيجار';
    if (n === 'utilities expense') return 'مصروفات المنافع (كهرباء وماء)';
    if (n === 'owner drawings') return 'مسحوبات المالك';
    if (n === 'owner equity') return 'حقوق الملكية';
    if (n === 'tax payable') return 'ضريبة مستحقة الدفع';
    if (n === 'discount given') return 'خصم مسموح به';
    if (n === 'discount received') return 'خصم مكتسب';
    if (n === 'delivery expense') return 'مصروفات التوصيل';

    // Default fallback if not matched
    return name;
};
