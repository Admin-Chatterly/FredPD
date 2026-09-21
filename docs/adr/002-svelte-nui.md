# ADR-002: Svelte 5 + TypeScript + Vite for the NUI

- **Status:** Accepted
- **Date:** 2026-09-17
- **Spec:** 3.3, 6

## Context

The NUI is the product: an MDC, a station terminal, a dispatch console, a lab
and a property room, all dense and keyboard-driven, running in CEF inside a
game that is also rendering a city. Spec 12 sets the budgets — the interface
opens in under 100 ms — and invariant 13 makes them acceptance criteria.

CEF gives us one known browser engine, so cross-browser support buys nothing.

Section 19 lists "UI framework confirmation (Svelte 5 or React)" as open until
the end of M1; this ADR records the default the work starts from.

## Decision

The NUI is **Svelte 5 with TypeScript, built by Vite**, styled with **Tailwind
4** using CSS-variable design tokens.

Supporting choices: TanStack Query for caching, TanStack Virtual for long
lists, TanStack Table core for grids, Tiptap for rich text stored as JSON,
Leaflet for the map, Lucide for icons.

## Consequences

- Svelte compiles away, so the runtime shipped to CEF is small and startup is
  fast — which is the budget that matters most here.
- Runes give fine-grained reactivity without a virtual DOM diff, so a dispatch
  board updating every second does not re-render a screen full of rows.
- One target (Chromium in CEF) means no polyfills and no browser matrix.
- Tailwind tokens put spec 6.2 in one file, which makes the "no gradients,
  glass, glow or neon" rule (6.6) reviewable rather than a matter of taste.
- The pool of developers who know Svelte is smaller than React's. Mitigated by
  the mock NUI bridge: the whole interface runs in a plain browser against
  fixtures, so a newcomer can work on it without a game server at all.
- A component library has to be assembled rather than adopted. Acceptable —
  spec 6 rejects the look of most component libraries anyway.

## Alternatives considered

**React.** Larger ecosystem and a bigger hiring pool; ox_mdt uses it. Heavier
runtime and more work to hold the startup budget. It remains the fallback if
Svelte proves a staffing problem before M1 closes — that is why section 19
keeps the question open until then.

**Vue.** No decisive advantage over Svelte here, and less proven in FiveM NUIs.

**Plain TypeScript with web components.** Smallest possible runtime, far more
hand-written machinery for forms, tables and state than this scope tolerates.
