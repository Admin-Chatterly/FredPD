---
name: new-page
description: Add a screen to the FredPD NUI. Use when building a new module view, record page, list or dialog in web/.
---

# Adding a page

Read spec **section 6** first, especially **6.6 (Rejected in review)**. This is
agency software: dense, flat, keyboard-driven. No gradients, glass, glow, neon
or emoji icons.

## 1. Place it

`web/src/modules/<module>/<Page>.svelte`. Shared pieces go in
`web/src/lib/components/`. A page renders inside the shell — title bar, module
rail, command line, tabs, context panel, status bar — it does not draw its own
frame (spec 6.3).

## 2. Fetch through the bridge

```ts
const response = await nui.call<PersonSummary[]>('records.person.search', { term });
```

Never `fetch`. Handle all three states explicitly: loading, loaded, and the
`{ ok: false, err }` envelope rendered as `t(\`error.${err}\`)`.

Add a fixture for the route in `web/src/lib/nui/fixtures.ts`, so the page works
in a browser with `pnpm dev:web` and can be tested without a game server.

## 3. Text

Every visible string is `t('key')`, with the key added to **both**
`resources/[fredpd]/fredpd/locales/en.json` and `sv.json`. Check Appendix A for
the Swedish police term — *anmälan*, not *rapport*. The `fredpd/no-literal-text`
ESLint rule fails the build on a bare string, including in `title`,
`aria-label`, `placeholder`, `alt` and `label`.

## 4. Style

Design tokens from `src/app.css` only — no hardcoded hex, no one-off spacing.
Check the page in **both** themes; night is the MDC default. Check it at MDC
width as well as full station-terminal width.

## 5. Permissions are the server's

Draw what the session was told it may see. Never decide access in the component
(invariant 4). A module the session cannot open does not appear in the rail
because the server did not list it — not because the component hid it.

## 6. Long lists

Virtualize with TanStack Virtual, paginate the query, and debounce
search-as-you-type. Spec 12's budgets are acceptance criteria.

## 7. Tests

A Playwright test in `web/tests/` against the mock bridge: the happy path, a
refusal path, and Swedish. Screenshot tests for key screens in both themes.

## Before you finish

`pnpm check && pnpm test:e2e`, then the `ui-reviewer` and `i18n-reviewer`
subagents.
