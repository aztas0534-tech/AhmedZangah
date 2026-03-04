import { defineConfig, devices } from 'playwright/test';

const baseURL = process.env.PLAYWRIGHT_BASE_URL || 'http://127.0.0.1:5174';
const useLocalStack = process.env.PLAYWRIGHT_USE_LOCAL === '1';
const webServerCommand = process.env.PLAYWRIGHT_WEB_SERVER_COMMAND || (useLocalStack ? 'npm run dev:local' : 'npm run dev -- --host 127.0.0.1 --port 5174');

export default defineConfig({
  testDir: './tests/e2e',
  timeout: 60_000,
  expect: { timeout: 15_000 },
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 2 : 1,
  reporter: [['html', { open: 'never' }], ['list']],
  use: {
    baseURL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    viewport: { width: 1365, height: 768 },
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  // globalSetup: './tests/e2e/global-setup.ts',
  webServer: {
    command: webServerCommand,
    url: baseURL,
    reuseExistingServer: true,
    timeout: useLocalStack ? 300_000 : 120_000,
  },
});
