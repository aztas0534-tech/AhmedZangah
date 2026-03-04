import * as xlsx from 'xlsx';
import { getSupabaseClient } from '../supabase';
import JSZip from 'jszip';

export interface BackupProgress {
    status: 'idle' | 'fetching_schema' | 'fetching_data' | 'generating_file' | 'completed' | 'error';
    currentTable: string;
    tableProgress: number; // 0 to 100 for current table
    tablesCompleted: number;
    totalTables: number;
    message: string;
}

export const exportFullSystemBackup = async (
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

    onProgress({ status: 'fetching_data', currentTable: '', tableProgress: 50, tablesCompleted: totalTables, totalTables, message: 'جاري حزم المرفقات والصور السحابية...' });

    const zip = new JSZip();
    zip.file('database.json', jsonString);

    try {
        const { data: buckets } = await supabase.storage.listBuckets();
        if (buckets && buckets.length > 0) {
            for (const bucket of buckets) {
                const { data: files } = await supabase.storage.from(bucket.name).list();
                if (files && files.length > 0) {
                    for (const file of files) {
                        if (file.name === '.emptyFolderPlaceholder') continue;
                        const { data: fileData, error: downloadError } = await supabase.storage.from(bucket.name).download(file.name);
                        if (fileData && !downloadError) {
                            zip.file(`storage/${bucket.name}/${file.name}`, fileData);
                        }
                    }
                }
            }
        }
    } catch (storageError) {
        console.warn('Failed to backup some storage files', storageError);
    }

    onProgress({ status: 'generating_file', currentTable: '', tableProgress: 100, tablesCompleted: totalTables, totalTables, message: 'جاري ضغط الملف النهائي للنسخة الاحتياطية...' });

    const blob = await zip.generateAsync({ type: 'blob', compression: 'DEFLATE', compressionOptions: { level: 6 } });

    onProgress({ status: 'completed', currentTable: '', tableProgress: 100, tablesCompleted: totalTables, totalTables, message: 'اكتملت عملية النسخ الاحتياطي الشامل بنجاح' });

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

export const importSystemBackup = async (
    file: File,
    isWipeRestore: boolean,
    onProgress: (progress: BackupProgress) => void
): Promise<void> => {
    const supabase = getSupabaseClient();
    if (!supabase) throw new Error('Supabase client not initialized');

    onProgress({ status: 'idle', currentTable: '', tableProgress: 0, tablesCompleted: 0, totalTables: 0, message: 'جاري قراءة وفك ضغط الملف...' });

    try {
        let content = '';
        let zip: JSZip | null = null;

        if (file.name.endsWith('.abdz') || file.name.endsWith('.zip')) {
            zip = await JSZip.loadAsync(file);
            const dbFile = zip.file('database.json');
            if (!dbFile) throw new Error('الملف المضغوط لا يحتوي على قاعدة بيانات database.json صالحة.');
            content = await dbFile.async('string');
        } else {
            // Legacy JSON support fallback (.abd)
            content = await new Promise<string>((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = e => resolve(e.target?.result as string);
                reader.onerror = () => reject(new Error('فشل قراءة الملف النصي.'));
                reader.readAsText(file);
            });
        }

        const parsed = JSON.parse(content);

        if (!parsed.version || !parsed.data) {
            throw new Error('الملف غير صالح للاسترداد أو أنه تالف.');
        }

        if (isWipeRestore) {
            onProgress({ status: 'idle', currentTable: 'WIPE', tableProgress: 0, tablesCompleted: 0, totalTables: 0, message: 'جاري التهيئة والمسح الشامل لقاعدة البيانات...' });
            const { error: wipeError } = await supabase.rpc('admin_wipe_all_tables_for_restore');
            if (wipeError) {
                console.error("Wipe failed", wipeError);
                throw new Error('فشل عملية مسح قاعدة البيانات للتهيئة: ' + wipeError.message);
            }
        }

        const tablesData = parsed.data;

        // Dependency Order (Parent tables first, then children)
        const priorityOrder = [
            'organization_settings',
            'branches',
            'warehouses',
            'chart_of_accounts',
            'financial_parties',
            'categories',
            'items',
            'item_warehouses',
            'cash_shifts',
            'invoices',
            'invoice_items',
            'purchases',
            'purchase_items',
            'inventory_movements',
            'journal_entries',
            'journal_entry_lines',
            'pos_sessions',
            'vouchers',
            'employees',
            'roles',
        ];

        const tables = Object.keys(tablesData);
        const sortedTables = tables.sort((a, b) => {
            const idxA = priorityOrder.indexOf(a);
            const idxB = priorityOrder.indexOf(b);
            if (idxA === -1 && idxB === -1) return 0;
            if (idxA === -1) return 1;
            if (idxB === -1) return -1;
            return idxA - idxB;
        });

        const totalTables = sortedTables.length;

        for (let i = 0; i < totalTables; i++) {
            const table = sortedTables[i];
            const dataArray = tablesData[table] || [];

            if (!Array.isArray(dataArray) || dataArray.length === 0) {
                onProgress({ status: 'fetching_data', currentTable: table, tableProgress: 100, tablesCompleted: i + 1, totalTables, message: `تجاوز جدول: ${table} (لا يحوي بيانات)` });
                continue;
            }

            onProgress({ status: 'fetching_data', currentTable: table, tableProgress: 0, tablesCompleted: i, totalTables, message: `جاري استرداد جدول: ${table} (${dataArray.length} سجل)` });

            // Chunking injection for large tables to not hit request limits
            const chunkSize = 2000;
            for (let j = 0; j < dataArray.length; j += chunkSize) {
                const chunk = dataArray.slice(j, j + chunkSize);

                const { data: res, error } = await supabase.rpc('admin_import_table_data', {
                    p_table: table,
                    p_data: chunk
                });

                if (error || (res && res.status === 'error')) {
                    console.error(`Restore error on table ${table}:`, error || res);
                    throw new Error(`تعذر استرداد جدول ${table}. التفاصيل: ${error?.message || res?.message}`);
                }

                onProgress({ status: 'fetching_data', currentTable: table, tableProgress: Math.min(100, ((j + chunkSize) / dataArray.length) * 100), tablesCompleted: i, totalTables, message: `جاري استرداد بيانات ${table} (${Math.min(dataArray.length, j + chunkSize)} / ${dataArray.length})` });
            }
        }

        if (zip) {
            onProgress({ status: 'fetching_data', currentTable: 'المرفقات', tableProgress: 0, tablesCompleted: totalTables, totalTables, message: 'جاري استرداد الملفات والمرفقات السحابية...' });
            const storageRegex = /^storage\/([^\/]+)\/(.*)$/;
            for (const relativePath of Object.keys(zip.files)) {
                const match = relativePath.match(storageRegex);
                if (match && !zip.files[relativePath].dir) {
                    const bucketName = match[1];
                    const fileName = match[2];
                    const fileData = await zip.files[relativePath].async('blob');
                    await supabase.storage.from(bucketName).upload(fileName, fileData, {
                        upsert: true
                    });
                }
            }
        }

        onProgress({ status: 'completed', currentTable: '', tableProgress: 100, tablesCompleted: totalTables, totalTables, message: 'تمت عملية الاسترداد الشامل بنجاح!' });
    } catch (error: any) {
        throw error;
    }
};
