# web/ — the NUI

Svelte 5 + TypeScript + Vite + Tailwind 4. Builds into
`resources/[fredpd]/fredpd/web/dist`. Read spec section 6 before any UI work.

## The bridge

Never call `fetch` directly. Everything goes through `src/lib/nui`:

```ts
const response = await nui.call<Session>('session.get');
if (response.ok) use(response.data);
else show(t(`error.${response.err}`));
```

`nui` is the real NUI transport inside FiveM and the fixture-backed mock in a
browser, chosen once in `src/lib/nui/index.ts`. Because of that, `pnpm dev:web`
runs the whole interface with no game server. Add a fixture in
`src/lib/nui/fixtures.ts` for every route you call.

Query parameters while developing: `?locale=sv`, `?latency=400`,
`?fail=forbidden`.

## Rules specific to this package

- **No literal user-facing text.** `fredpd/no-literal-text` fails the build on a
  bare string in markup or in `title`, `aria-label`, `placeholder`, `alt`,
  `label`. Use `t('key')` and add the key to **both** `en.json` and `sv.json`.
- **The UI is never the access control** (invariant 4). Draw what the server
  said this session may see; never decide it here.
- **Section 6.6 is strict**: no gradients, glass, glow, neon or emoji icons.
  Icons are Lucide SVG. Dense, flat, keyboard-driven agency software.
- Colors come from the design tokens in `src/app.css`, never hardcoded hex.
- The CSP in `index.html` allows the bundle, `nui://` and the media host only.
  Nothing loads from a CDN — no remote fonts, no remote scripts.

## Tests

- `pnpm test` — Vitest, pure logic only (no DOM).
- `pnpm test:e2e` — Playwright against the mock bridge, in both languages.
  Set `PLAYWRIGHT_CHROMIUM_EXECUTABLE` to reuse an existing Chromium.
