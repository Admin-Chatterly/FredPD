# gateway/ — the Node.js service

TypeScript on Node 24, Fastify, pino. Runs on the same host as FXServer, under
systemd. Read spec sections 3.7 (interface), 4.2 (Discord sync) and 11
(security) before working here.

Responsibilities: the Discord bot and role sync, the media store, PDF
rendering, scheduled jobs (retention, lab timers, warrant expiry), and later the
web portal.

## Rules specific to this package

- **Loopback only.** The gateway binds `127.0.0.1`. The outside world reaches it
  through Caddy, never directly.
- **Everything FXServer calls is signed.** Routes live under `/fx`, where the
  plugin-scoped `preHandler` verifies the HMAC before anything parses the body.
  A new FXServer-facing route goes inside that scope — never outside it.
- **Verify against the raw body.** The JSON parser is registered `parseAs:
  'string'` on purpose: re-serializing before verifying would check a different
  byte sequence than the one that was signed.
- **One failure shape.** A rejected request gets `401 { ok: false, err:
  'forbidden' }`. Never report which check failed, or how close it was.
- **Secrets come from the environment**, never from a file in the repo
  (invariant 7). A missing secret is a boot failure, not a warning.
- **Discord stays the source of truth.** Role changes go FredPD → gateway → bot
  → Discord, then flow back through the sync. Never mirror permissions locally
  as the authority.
- Log with pino, and never log a record's contents, a token or a secret.

## Tests

`pnpm test` — Vitest. Use `app.inject()` rather than a live socket. The
signature tests use a fixed clock, so they must never depend on `Date.now()`.
