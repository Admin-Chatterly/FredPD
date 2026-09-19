import { defineConfig, mergeConfig } from 'vitest/config';

import viteConfig from './vite.config.ts';

/**
 * Unit tests for the NUI's pure logic (i18n, the bridge envelope). Anything
 * that needs a browser is a Playwright test instead (spec 15).
 */
export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: 'node',
      include: ['src/**/*.test.ts'],
    },
  }),
);
