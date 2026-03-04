import React, { useState } from 'react';
import {
    exportFullDatabaseAsJson,
    exportSummaryAsExcel,
    downloadBlob,
    BackupProgress
} from '../../../utils/backupUtils';
import { useToast } from '../../../contexts/ToastContext';
import * as Icons from '../../../components/icons';

const BackupSettingsScreen: React.FC = () => {
    const { showNotification } = useToast();
    const [isBackingUp, setIsBackingUp] = useState(false);
    const [backupType, setBackupType] = useState<'json' | 'excel' | null>(null);
    const [progress, setProgress] = useState<BackupProgress>({
        status: 'idle',
        currentTable: '',
        tableProgress: 0,
        tablesCompleted: 0,
        totalTables: 0,
        message: ''
    });

    const handleBackupJson = async () => {
        try {
            setIsBackingUp(true);
            setBackupType('json');
            const blob = await exportFullDatabaseAsJson(setProgress);
            const filename = `AhmedZ_Full_Backup_${new Date().toISOString().replace(/[:.]/g, '-')}.abd`;
            downloadBlob(blob, filename);
            showNotification('تم اكتمال النسخ الاحتياطي (النسخة الشاملة) بنجاح!', 'success');
        } catch (error: any) {
            showNotification(error.message || 'حدث خطأ أثناء سحب البيانات.', 'error');
            setProgress((p: BackupProgress) => ({ ...p, status: 'error', message: 'فشلت العملية' }));
        } finally {
            setIsBackingUp(false);
            setTimeout(() => setBackupType(null), 3000); // clear after 3s
        }
    };

    const handleBackupExcel = async () => {
        try {
            setIsBackingUp(true);
            setBackupType('excel');
            const blob = await exportSummaryAsExcel(setProgress);
            const filename = `AhmedZ_Summary_${new Date().toISOString().split('T')[0]}.xlsx`;
            downloadBlob(blob, filename);
            showNotification('تم تصدير نسخة الإكسيل المقروءة بنجاح!', 'success');
        } catch (error: any) {
            showNotification(error.message || 'حدث خطأ أثناء تصدير الإكسيل.', 'error');
            setProgress((p: BackupProgress) => ({ ...p, status: 'error', message: 'فشلت العملية' }));
        } finally {
            setIsBackingUp(false);
            setTimeout(() => setBackupType(null), 3000);
        }
    };

    const calculateOverallProgress = () => {
        if (progress.totalTables === 0) return 0;
        // tablesCompleted is integer, tableProgress is 0-100 for current table
        const completedFraction = progress.tablesCompleted / progress.totalTables;
        const currentFraction = (progress.tableProgress / 100) / progress.totalTables;
        const totalPercentage = (completedFraction + currentFraction) * 100;
        return Math.min(100, Math.max(0, Math.round(totalPercentage)));
    };

    return (
        <div className="animate-fade-in space-y-8 max-w-5xl mx-auto">
            <div>
                <h1 className="text-3xl font-bold dark:text-white mb-2">النسخ الاحتياطي وأمان البيانات</h1>
                <p className="text-gray-600 dark:text-gray-300">
                    احتفظ بنسخة من بيانات متجرك وحساباتك بأمان على جهازك الشخصي لتكون دائماً مطمئناً.
                </p>
            </div>

            {isBackingUp && backupType && (
                <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl border border-blue-200 dark:border-blue-700 p-8 relative overflow-hidden">
                    <div className="absolute top-0 left-0 w-full h-1 bg-gray-200 dark:bg-gray-700">
                        <div
                            className="h-full bg-blue-600 transition-all duration-300 ease-out"
                            style={{ width: `${calculateOverallProgress()}%` }}
                        />
                    </div>

                    <div className="flex flex-col items-center justify-center space-y-6">
                        <div className={`p-4 rounded-full ${backupType === 'excel' ? 'bg-green-100 text-green-600 dark:bg-green-900/30 dark:text-green-400' : 'bg-blue-100 text-blue-600 dark:bg-blue-900/30 dark:text-blue-400'} animate-pulse`}>
                            {backupType === 'excel' ? <Icons.ReportIcon className="h-10 w-10" /> : <Icons.DatabaseIcon className="h-10 w-10" />}
                        </div>

                        <div className="text-center">
                            <h3 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
                                {backupType === 'excel' ? 'جاري تصدير الإكسيل...' : 'جاري سحب الهيكل الكامل...'}
                            </h3>
                            <p className="text-gray-600 dark:text-gray-300 text-lg font-mono" dir="rtl">
                                {progress.message}
                            </p>
                        </div>

                        <div className="w-full max-w-md bg-gray-100 dark:bg-gray-700 rounded-lg p-4">
                            <div className="flex justify-between text-sm mb-2 text-gray-700 dark:text-gray-300 font-semibold">
                                <span>التقدم الإجمالي</span>
                                <span>{calculateOverallProgress()}%</span>
                            </div>
                            <div className="w-full bg-gray-300 dark:bg-gray-600 rounded-full h-2.5">
                                <div className={`h-2.5 rounded-full ${backupType === 'excel' ? 'bg-green-500' : 'bg-blue-600'}`} style={{ width: `${calculateOverallProgress()}%` }}></div>
                            </div>
                            {progress.status === 'fetching_data' && (
                                <div className="mt-4 border-t dark:border-gray-600 pt-3 flex justify-between text-xs text-gray-500 dark:text-gray-400 font-mono">
                                    <span>الجدول الحالي: {progress.currentTable}</span>
                                    <span>({progress.tablesCompleted + 1} / {progress.totalTables})</span>
                                </div>
                            )}
                        </div>
                    </div>
                </div>
            )}

            <div className={`grid grid-cols-1 md:grid-cols-2 gap-6 ${isBackingUp ? 'opacity-50 pointer-events-none' : ''}`}>
                {/* Excel Backup Card */}
                <div className="bg-white dark:bg-gray-800 rounded-2xl shadow-lg border border-gray-100 dark:border-gray-700 p-8 flex flex-col hover:shadow-xl transition relative overflow-hidden group">
                    <div className="absolute -right-4 -top-4 bg-green-50 dark:bg-green-900/10 w-32 h-32 rounded-full opacity-50 group-hover:scale-110 transition-transform"></div>
                    <div className="relative z-10 flex-1">
                        <div className="bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400 w-14 h-14 rounded-2xl flex items-center justify-center mb-6">
                            <Icons.ReportIcon className="h-7 w-7" />
                        </div>
                        <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-3">نسخة مقروءة (Excel)</h2>
                        <p className="text-gray-600 dark:text-gray-400 mb-6 leading-relaxed">
                            تصدير الجداول الأساسية (الأصناف، فواتير المشتريات والمبيعات، الحسابات، والعملاء والموردين) في ملف إكسيل واحد مرتب ومبوب. مخصص ليتصفحه التاجر في أي وقت للطمأنينة أو لمشاركته مع المستشار المحاسبي.
                        </p>
                    </div>
                    <button
                        onClick={handleBackupExcel}
                        className="w-full py-4 rounded-xl font-bold text-white bg-green-600 hover:bg-green-700 shadow-md hover:shadow-lg transition-all flex items-center justify-center gap-2"
                    >
                        <Icons.DownloadIcon className="h-5 w-5" />
                        تحميل نسخة الإكسيل
                    </button>
                </div>

                {/* Database Backup Card */}
                <div className="bg-white dark:bg-gray-800 rounded-2xl shadow-lg border border-gray-100 dark:border-gray-700 p-8 flex flex-col hover:shadow-xl transition relative overflow-hidden group">
                    <div className="absolute -right-4 -top-4 bg-blue-50 dark:bg-blue-900/10 w-32 h-32 rounded-full opacity-50 group-hover:scale-110 transition-transform"></div>
                    <div className="relative z-10 flex-1">
                        <div className="bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400 w-14 h-14 rounded-2xl flex items-center justify-center mb-6">
                            <Icons.DatabaseIcon className="h-7 w-7" />
                        </div>
                        <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-3">نسخة شاملة للنظام (.abd)</h2>
                        <p className="text-gray-600 dark:text-gray-400 mb-6 leading-relaxed">
                            سحب كامل 100% لكل صغيرة وكبيرة في قاعدة البيانات (الهيكل والبيانات والمعرفات الفريدة UUID). هذا الملف يستخدم كنسخة أمان مطلقة، أو لرفعها مستقبلاً عند الانتقال لسيرفر/قاعدة بيانات أخرى واستئناف العمل دون فقدان شيء.
                        </p>
                    </div>
                    <button
                        onClick={handleBackupJson}
                        className="w-full py-4 rounded-xl font-bold text-white bg-blue-600 hover:bg-blue-700 shadow-md hover:shadow-lg transition-all flex items-center justify-center gap-2"
                    >
                        <Icons.DownloadIcon className="h-5 w-5" />
                        تحميل نسخة قاعدة البيانات الشاملة
                    </button>
                </div>
            </div>

        </div>
    );
};

export default BackupSettingsScreen;
