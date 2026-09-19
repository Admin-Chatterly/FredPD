import { existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

import { defineConfig, devices } from '@playwright/test';

/**
 * UI tests (spec 15) run the NUI in a real browser against the mock bridge, so
 * no game server and no database are involved.
 */

const PORT = 4173;

/**
 * The Chromium to launch, or `undefined` to let Playwright manage its own.
 *
 * `PLAYWRIGHT_CHROMIUM_EXECUTABLE` is the explicit answer and always wins.
 *
 * The fallback exists because `pnpm verify` -- the one command CLAUDE.md tells
 * everybody to run before committing -- could not pass in a prepared sandbox.
 * Those images set `PLAYWRIGHT_BROWSERS_PATH` to a directory that already holds
 * a Chromium and set `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` so nothing fetches a
 * second one. But the browser in the image is whatever build was current when
 * it was made, and `@playwright/test` in this repo pins a different one, so
 * Playwright looked for a revision that was not there and failed all fourteen
 * tests with "Please run playwright install" -- advice that cannot work, since
 * the download it asks for is the thing that was switched off.
 *
 * Fourteen red tests and an instruction that fails is indistinguishable from a
 * broken suite. The next person to meet it concludes the tests are broken
 * rather than their change, and the gate stops being a gate -- which is the
 * exact drift `pnpm verify` was added to stop.
 *
 * So: if the image says where its browsers live and one is a Chromium, use it.
 * A revision or two of drift from the pinned build does not matter here,
 * because these tests assert what a Svelte app renders, not browser behaviour.
 * CI installs the pinned browser properly and never reaches this path.
 */
function discoverChromium(): string | undefined {
    const explicit = process.env['PLAYWRIGHT_CHROMIUM_EXECUTABLE'];
    if (explicit) return explicit;

    const root = process.env['PLAYWRIGHT_BROWSERS_PATH'];
    if (!root || root === '0' || !existsSync(root)) return undefined;

    // Newest first, so an image carrying two builds gives the later one. The
    // headless shell is excluded deliberately: it is a separate, smaller
    // download that images do not always carry, and the full browser is what
    // CEF is.
    const candidates = readdirSync(root)
        .filter((name) => name === 'chromium' || /^chromium-\d+$/.test(name))
        .sort()
        .reverse();

    for (const name of candidates) {
        for (const suffix of ['', 'chrome-linux/chrome', 'chrome-mac/Chromium.app/Contents/MacOS/Chromium']) {
            const path = suffix ? join(root, name, suffix) : join(root, name);

            // `statSync` rather than `existsSync`, because the bare `chromium`
            // entry is usually a symlink to the executable inside a versioned
            // directory and a broken one must not be returned.
            try {
                if (statSync(path).isFile()) return path;
            } catch {
                // Not there, or a dangling link. Try the next shape.
            }
        }
    }

    return undefined;
}

const CHROMIUM = discoverChromium();

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
  // `discoverChromium` above decides which one, and why.
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        ...(CHROMIUM ? { launchOptions: { executablePath: CHROMIUM } } : {}),
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
