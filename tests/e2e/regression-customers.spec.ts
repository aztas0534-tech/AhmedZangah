import { test, expect } from '@playwright/test';
import { adminStorageStatePath } from './global-setup';

test.use({ storageState: adminStorageStatePath });

test.describe.serial('Regression V2: Customers', () => {
  test('Customers management excludes admin users and includes business customer', async ({ page }) => {
    await page.goto('/#/admin/customers', { waitUntil: 'domcontentloaded' });
    await expect(page.getByRole('main').getByRole('heading', { name: 'إدارة العملاء' })).toBeVisible({ timeout: 60_000 });

    await expect(page.getByText('Smoke Customer').first()).toBeVisible({ timeout: 60_000 });
    await expect(page.getByText('owner@azta.com')).toHaveCount(0);
    await expect(page.getByText('smoke-admin@local.test')).toHaveCount(0);
  });
});
