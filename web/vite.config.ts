import { fileURLToPath, URL } from 'node:url';

import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import tailwindcss from '@tailwindcss/vite';

const resourceRoot = fileURLToPath(new URL('../resources/[fredpd]/fredpd', import.meta.url));

// `index.html`'s CSP interpolates `%VITE_MEDIA_HOST%` (Vite's HTML env
// replacement) so the gateway's media origin can be named without a
// wildcard (invariant 9). Left unset, Vite leaves the literal `%…%` in the
// built HTML and warns on every build; a same-origin loopback default keeps
// `pnpm dev:web` and a default build quiet, and a real deployment overrides
// it with the gateway's actual `FREDPD_MEDIA_BASE_URL`.
process.env['VITE_MEDIA_HOST'] ??= 'http://127.0.0.1:3080';

export default defineConfig({
  plugins: [svelte(), tailwindcss()],

  resolve: {
    alias: {
      // One source of truth for locale files: the resource ships them to the
      // game, and the NUI imports the very same JSON (spec 5.1).
      '@locales': `${resourceRoot}/locales`,
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },

  server: {
    fs: {
      // The locale files live outside web/, so Vite needs them allowed.
      allow: ['..'],
    },
  },

  // The NUI is loaded from disk by CEF, so every asset reference has to be
  // relative rather than rooted at '/'.
  base: './',

  build: {
    outDir: `${resourceRoot}/web/dist`,
    emptyOutDir: true,
    target: 'chrome108',
    sourcemap: true,
    rollupOptions: {
      output: {
        // fxmanifest lists assets by extension, so keep them predictable and flat.
        entryFileNames: 'assets/[name].js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: 'assets/[name][extname]',
      },
    },
  },
});
