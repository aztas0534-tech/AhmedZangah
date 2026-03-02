export function numberToArabicWords(number: number, currencyName: string = 'ريال', subunitName: string = 'هللة'): string {
    if (number === 0) return 'صفر ' + currencyName;

    const [integerPartStr, decimalPartStr] = number.toFixed(2).split('.');
    const integerPart = parseInt(integerPartStr, 10);
    const decimalPart = parseInt(decimalPartStr, 10);

    const units = ['', 'واحد', 'اثنان', 'ثلاثة', 'أربعة', 'خمسة', 'ستة', 'سبعة', 'ثمانية', 'تسعة'];
    const tens = ['', 'عشرة', 'عشرون', 'ثلاثون', 'أربعون', 'خمسون', 'ستون', 'سبعون', 'ثمانون', 'تسعون'];
    const thousands = ['', 'ألف', 'مليون', 'مليار', 'تريليون'];

    function convertGroup(n: number): string {
        if (n === 0) return '';
        let result = '';

        const h = Math.floor(n / 100);
        const t = Math.floor((n % 100) / 10);
        const u = n % 10;

        if (h > 0) {
            if (h === 1) result += 'مائة';
            else if (h === 2) result += 'مائتان';
            else result += units[h] + 'مائة';
        }

        if (u > 0 || t > 0) {
            if (h > 0) result += ' و ';

            if (t === 0) {
                result += units[u];
            } else if (t === 1) {
                if (u === 0) result += 'عشرة';
                else if (u === 1) result += 'أحد عشر';
                else if (u === 2) result += 'اثنا عشر';
                else result += units[u] + ' عشر';
            } else {
                if (u > 0) result += units[u] + ' و ' + tens[t];
                else result += tens[t];
            }
        }

        return result;
    }

    let intResult = '';
    let num = integerPart;
    let groupIdx = 0;

    while (num > 0) {
        const group = num % 1000;
        if (group > 0) {
            let groupStr = '';
            if (groupIdx === 0) {
                groupStr = convertGroup(group);
            } else if (groupIdx > 0) {
                if (group === 1) groupStr = thousands[groupIdx];
                else if (group === 2) {
                    if (groupIdx === 1) groupStr = 'ألفان';
                    else if (groupIdx === 2) groupStr = 'مليونان';
                    else if (groupIdx === 3) groupStr = 'ملياران';
                } else if (group >= 3 && group <= 10) {
                    if (groupIdx === 1) groupStr = convertGroup(group) + ' آلاف';
                    else if (groupIdx === 2) groupStr = convertGroup(group) + ' ملايين';
                    else if (groupIdx === 3) groupStr = convertGroup(group) + ' مليارات';
                } else {
                    groupStr = convertGroup(group) + ' ' + thousands[groupIdx];
                }
            }
            intResult = groupStr + (intResult ? ' و ' + intResult : '');
        }
        num = Math.floor(num / 1000);
        groupIdx++;
    }

    let result = '';
    if (intResult) {
        result += 'فقط ' + intResult + ' ' + currencyName;
    } else {
        result += 'فقط ' + 'صفر ' + currencyName;
    }

    if (decimalPart > 0) {
        result += ' و' + convertGroup(decimalPart) + ' ' + subunitName;
    }

    return result + ' لا غير';
}
