# gateway/ — the Node.js service

TypeScript on Node 24, Fastify, pino. Runs on the same host as FXServer, under
systemd. Read spec sections 3.7 (interface), 4.2 (Discord sync) and 11
(security) before working here.

Responsibilities: the media store, PDF rendering, scheduled jobs (lab timers,
warrant expiry; retention moved to FXServer), Discord role *actions* (hire,
promote, demote, dismiss; ADR-022, `src/discord/roles.ts`), and later the web
portal. Role actions use a bot of their own, off by default, and never touch a
role missing from `FREDPD_ROLE_ACTIONS_ALLOWED`, whatever FXServer asks. The media store is built and in use: photographs of
people (ADR-019), re-encoded on upload, single-use upload tokens, and CORS for
the NUI's origin only. PDF rendering is in use for printed documents (ADR-020):
letterhead, page numbers, the document number and a classification watermark
on every page. The scheduler exists but is superseded for retention: that runs
inside FXServer (ADR-021), and the gateway is asked only to delete the files of
abandoned uploads (`/fx/media/delete`). Do not add a sweep here.

**Reading Discord roles is no longer this service's job.** It moved into
FXServer (`server/core/discord.lua`, ADR-010) so that a normal install deploys
no Node at all. The gateway is off by default; do not add anything here that an
install is required to run.

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
  → Discord, then flow back through FXServer's own sync. Never mirror
  permissions locally as the authority, and never write `fpd_discord_members`
  from here — one writer, and it is not this one.
- Log with pino, and never log a record's contents, a token or a secret.

## Tests

`pnpm test` — Vitest. Use `app.inject()` rather than a live socket. The
signature tests use a fixed clock, so they must never depend on `Date.now()`.
