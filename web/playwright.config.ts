import { defineConfig, devices } from '@playwright/test';

/**
 * UI tests (spec 15) run the NUI in a real browser against the mock bridge, so
 * no game server and no database are involved.
 */

const PORT = 4173;

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env['CI'],
  retries: process.env['CI'] ? 2 : 0,
  reporter: process.env['CI'] ? [['github'], ['html', { open: 'never' }]] : [['list']],

  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    trace: 'on-first-retry',
  },

  // The NUI only ever runs in CEF, which is Chromium. Testing anything else
  // would be testing a browser the game will never use.
  //
  // PLAYWRIGHT_CHROMIUM_EXECUTABLE points at an existing Chromium where one is
  // already provided (a prepared CI image, a sandbox), instead of downloading a
  // second copy. Unset, Playwright uses its own managed browser as usual.
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        ...(process.env['PLAYWRIGHT_CHROMIUM_EXECUTABLE']
          ? { launchOptions: { executablePath: process.env['PLAYWRIGHT_CHROMIUM_EXECUTABLE'] } }
          : {}),
      },
    },
  ],

  webServer: {
    // `--host 127.0.0.1` is not optional on a CI runner. Left to itself Vite
    // binds `localhost`, which can resolve to ::1 only, while Playwright polls
    // 127.0.0.1 and waits out the full timeout. It passes locally either way,
    // so this is the kind of difference only CI finds.
    command: `pnpm vite --port ${PORT} --strictPort --host 127.0.0.1`,
    url: `http://127.0.0.1:${PORT}`,
    reuseExistingServer: !process.env['CI'],
    timeout: 120_000,
  },
});
