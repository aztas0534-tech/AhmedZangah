import { getSupabaseClient } from '../supabase';

export interface BackupProgress {
    status: 'idle' | 'fetching_schema' | 'fetching_data' | 'generating_file' | 'completed' | 'error';
    currentTable: string;
    tableProgress: number; // 0 to 100 for current table
    tablesCompleted: number;
    totalTables: number;
    message: string;
}

export const exportFullDatabaseAsJson = async (
    onProgress: (progress: BackupProgress) => void
): Promise<Blob> => {
    const supabase = getSupabaseClient();
    if (!supabase) throw new Error('Supabase client not initialized');

    onProgress({ status: 'fetching_schema', currentTable: '', tableProgress: 0, tablesCompleted: 0, totalTables: 0, message: 'جاري جلب هيكل قاعدة البيانات...' });

    const { data: tables, error: schemaError } = await supabase.rpc('admin_get_all_tables');
    if (schemaError) throw new Error(schemaError.message || 'فشل في قراءة الجداول، تأكد من الصلاحيات.');
    if (!tables || !Array.isArray(tables)) throw new Error('No tables found or invalid response');

    const totalTables = tables.length;
    const backupData: Record<string, any[]> = {};

    for (let i = 0; i < totalTables; i++) {
        const table = tables[i];
        onProgress({ status: 'fetching_data', currentTable: table, tableProgress: 0, tablesCompleted: i, totalTables, message: `جاري سحب الجداول: ${table}` });

        const chunkSize = 5000;
        let offset = 0;
        let tableData: any[] = [];
        let hasMore = true;

        while (hasMore) {
            const { data: chunk, error: dataError } = await supabase.rpc('admin_export_table_data', {
                p_table: table,
                p_offset: offset,
                p_limit: chunkSize
            });

            if (dataError) throw new Error(`Failed to fetch data for ${table}: ${dataError.message}`);

            const chunkArray = Array.isArray(chunk) ? chunk : [];
            tableData = tableData.concat(chunkArray);

            if (chunkArray.length < chunkSize) {
                hasMore = false;
            } else {
                offset += chunkSize;
                onProgress({ status: 'fetching_data', currentTable: table, tableProgress: Math.min(99, offset / 1000), tablesCompleted: i, totalTables, message: `جاري سحب بيانات: ${table} (${tableData.length} سجل)` });
            }
        }

        backupData[table] = tableData;
    }

    onProgress({ status: 'generating_file', currentTable: '', tableProgress: 100, tablesCompleted: totalTables, totalTables, message: 'جاري تشفير وتجميع الملف...' });

    const finalObject = {
        version: '1.0',
        timestamp: new Date().toISOString(),
        source: 'AhmedZ ERP System Backup',
        data: backupData
    };

    const jsonString = JSON.stringify(finalObject);
    const blob = new Blob([jsonString], { type: 'application/json' });

    onProgress({ status: 'completed', currentTable: '', tableProgress: 100, tablesCompleted: totalTables, totalTables, message: 'اكتملت عملية النسخ الاحتياطي بنجاح' });

    return blob;
};

export const exportSummaryAsExcel = async (
    onProgress: (progress: BackupProgress) => void
): Promise<Blob> => {
    const supabase = getSupabaseClient();
    if (!supabase) throw new Error('Supabase client not initialized');

    const tablesToExport = [
        { name: 'items', label: 'الأصناف' },
        { name: 'categories', label: 'الفئات' },
        { name: 'financial_parties', label: 'العملاء والجهات' },
        { name: 'suppliers', label: 'الموردين' },
        { name: 'chart_of_accounts', label: 'دليل الحسابات' },
        { name: 'invoices', label: 'فواتير المبيعات' },
        { name: 'purchases', label: 'فواتير المشتريات' },
        { name: 'inventory_movements', label: 'حركة المخزون' }
    ];

    const totalTables = tablesToExport.length;
    const workbook = xlsx.utils.book_new();

    for (let i = 0; i < totalTables; i++) {
        const tableDef = tablesToExport[i];
        onProgress({ status: 'fetching_data', currentTable: tableDef.label, tableProgress: 0, tablesCompleted: i, totalTables, message: `جاري سحب بيانات: ${tableDef.label}` });

        const { data: chunk, error: dataError } = await supabase.rpc('admin_export_table_data', {
            p_table: tableDef.name,
            p_offset: 0,
            p_limit: 50000
        });

        if (dataError) throw new Error(`Failed to fetch data for ${tableDef.label}: ${dataError.message}`);

        const chunkArray = Array.isArray(chunk) ? chunk : [];

        const flatData = chunkArray.map(row => {
            const flat: any = {};
            for (const key in row) {
                if (typeof row[key] === 'object' && row[key] !== null) {
                    flat[key] = JSON.stringify(row[key]);
                } else {
                    flat[key] = row[key];
                }
            }
            return flat;
        });

        const worksheet = xlsx.utils.json_to_sheet(flatData.length > 0 ? flatData : [{ 'فارغ': 'لا توجد بيانات' }]);

        if (!worksheet['!views']) worksheet['!views'] = [];
        worksheet['!views'].push({ rightToLeft: true });

        xlsx.utils.book_append_sheet(workbook, worksheet, tableDef.label.substring(0, 31));
    }

    onProgress({ status: 'generating_file', currentTable: '', tableProgress: 100, tablesCompleted: totalTables, totalTables, message: 'جاري إنشاء ملف الإكسيل...' });

    const excelBuffer = xlsx.write(workbook, { bookType: 'xlsx', type: 'array' });
    const blob = new Blob([excelBuffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });

    onProgress({ status: 'completed', currentTable: '', tableProgress: 100, tablesCompleted: totalTables, totalTables, message: 'تم إنشاء تقرير الإكسيل بنجاح' });

    return blob;
};

export const downloadBlob = (blob: Blob, filename: string) => {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
};
