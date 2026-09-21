# ADR-007: The internal police channel lives in the game chat

- **Status:** Accepted
- **Date:** 2026-09-17
- **Spec:** 7.26, 0 (invariants 1, 4, 5, 11)

## Context

Officers need a text channel among themselves. FredPD has an MDT, so the
obvious place is a chat panel inside it — and that is exactly the wrong place,
because it means an officer must open the MDT, and keep it open, to see what
their colleagues are saying. In a pursuit nobody has the MDT open.

The generic FiveM chat is already on screen, already has a history, already
handles focus and input, and officers already read it.

## Decision

The internal police channel renders in the **standard FiveM chat box**, sent
with `/pd <message>` (command configurable). The MDT keeps a comms log of the
same messages for anyone with `comms.pdchat.view`, but reading the channel live
never requires opening it.

## Consequences

- Officers see police traffic without changing what they are doing, which is
  the only version of this feature that gets used.
- No new UI surface, no focus handling, no unread badge to get wrong.
- **The recipient list is computed per message on the server.** A message goes
  only to sessions holding `comms.pdchat.view`, never with a broadcast
  (invariant 5). Using the shared chat box makes this the thing most likely to
  be got wrong, so it is the thing the tests cover first: a civilian must not
  receive a police message even though they have the same chat box open.
- **The author is resolved server-side.** Callsign, name and agency come from
  the session and are prefixed by the server; nothing about the author is taken
  from the client (invariant 1). Otherwise any client could post as anyone.
- The body is length-capped and stripped of chat colour codes (`^1`…`^9`), so
  the channel cannot be used to forge another officer's prefix or to paint the
  chat box.
- Messages are stored append-only in `fpd_chat_messages` (invariant 11), which
  makes the channel reviewable after an incident instead of ephemeral.
- **Cost:** the chat box is shared with every other resource, so FredPD does not
  control what else appears there, and a player can screenshot it like any chat.
  Accepted — this is officer chatter, not restricted record content. Anything
  classified belongs in a record with an access check, not in a chat line.

## Alternatives considered

**A chat panel in the MDT.** Fully under our control and styleable to section 6,
but invisible unless the MDT is open, which defeats the purpose.

**Both, from day one.** The MDT comms log is in scope; a live MDT chat view is
not worth building until someone asks for it.

**Radio only (pma-voice).** Voice already exists and is the primary channel.
Text complements it for anything that needs to be exact — a plate, an address,
a callsign — which is precisely what voice is bad at.
