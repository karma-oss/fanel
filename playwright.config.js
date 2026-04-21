const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests/smoke',
  timeout: 15000,
  retries: 0,
  use: {
    headless: true,
    baseURL: 'http://127.0.0.1:9222',
  },
  webServer: {
    command: 'node tests/serve-html.js',
    port: 9222,
    reuseExistingServer: true,
  },
  projects: [
    { name: 'chromium', use: { browserName: 'chromium' } },
  ],
});
