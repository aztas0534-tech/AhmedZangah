import { test, expect } from '@playwright/test';
import { runSmokeSql } from './utils/runSmokeSql';

test.describe.serial('Regression V2: Database', () => {
  test('smoke_regression_v2.sql passes', async () => {
    const reportPath = runSmokeSql({
      sqlRelPath: 'supabase/smoke/smoke_regression_v2.sql',
      okToken: 'REGRESSION_V2_OK',
      reportNamePrefix: 'REGRESSION_V2_DB',
    });
    expect(reportPath).toContain('REGRESSION_V2_DB');
  });
});

