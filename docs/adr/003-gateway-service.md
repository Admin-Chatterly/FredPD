# ADR-003: A separate Node.js gateway service

- **Status:** Accepted
- **Date:** 2026-09-17
- **Spec:** 3.2, 3.7, 4.2

## Context

Several things FredPD needs do not belong on the game server's thread, or
cannot be done there at all:

- a **Discord bot** holding a gateway connection with the Server Members
  intent, to sync roles and to act on them (hire, promote, suspend);
- **media**: receiving uploads, re-encoding them, serving signed URLs;
- **PDF rendering** for reports, warrants and discovery packages, which means
  headless Chromium;
- **scheduled jobs**: retention, lab turnaround timers, warrant expiry.

FXServer is a game server. Blocking its thread costs every player frames, and a
Discord outage or a slow image resize must never be able to do that.

## Decision

A **Node.js 24 service** (`gateway/`), TypeScript with Fastify and pino, on the
same host, under systemd with automatic restart.

FXServer and the gateway talk over **loopback HTTP, HMAC-signed in both
directions**, with a timestamp inside the signed material and a 30-second replay
window. An outbox table on each side makes delivery survive a restart.

The gateway binds `127.0.0.1`. Public traffic (media, and later the portal)
arrives through Caddy, which terminates TLS.

## Consequences

- Slow or failing work is isolated from the game thread by a process boundary.
- The gateway can restart — for a deploy, or after a crash — without dropping
  players, and the outbox replays what was missed.
- Node's ecosystem gives us discord.js, sharp and Playwright directly, rather
  than reimplementing any of them in Lua.
- **Cost:** two processes to deploy, monitor and keep in version step, and a new
  trust boundary. That boundary is the reason the HMAC is mandatory rather than
  optional: an unsigned loopback service would let anything on the host issue
  role changes and mint media tokens. A missing secret is a boot failure.
- Signature verification happens against the **raw request body**, before any
  parsing, because re-serializing would verify a different byte sequence than
  the one that was signed.
- Rejections return one shape (`401 { ok: false, err: 'forbidden' }`) and never
  say which check failed.

## Alternatives considered

**Everything inside FXServer.** Fewer moving parts, but headless Chromium and a
Discord gateway connection on the game thread are not acceptable, and a crash
takes the server with it.

**A hosted service on another machine.** Removes the host-local trust
assumption, adds network latency to every role check and another failure domain.
Reconsider only if the deployment stops being a single dedicated host.

**Discord role checks straight from FXServer.** Rate limits and outage handling
would live on the game thread, and every Discord hiccup would become a gameplay
hiccup. Spec 4.2 keeps FXServer from calling Discord at all.
