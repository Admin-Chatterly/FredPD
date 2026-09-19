# ADR-004: Discord roles as the only permission source

- **Status:** Accepted
- **Date:** 2026-09-17
- **Spec:** 0 (invariant 2), 4.2, 4.3

## Context

A police department on a roleplay server already administers itself in Discord:
ranks, units, divisions, DOJ, internal affairs. Hiring, promotion and dismissal
happen there, and Discord is where staff look to answer "should this person have
access?"

A FiveM framework also carries a job and a grade per character. Using both as
permission sources means two places to revoke access — and the one everybody
forgets is the one that matters after somebody is dismissed.

## Decision

**Discord roles are the only source of permissions** (invariant 2).

Framework job and grade are **context conditions** layered on top of a grant
that a Discord role already provided (spec 4.3): "on duty", "in this unit", "at
this access point". They never grant anything by themselves.

Mechanically: the gateway's bot snapshots every member holding a mapped role
into `fpd_discord_members` and pushes changes as they happen. FXServer never
calls Discord. Role actions initiated in FredPD go out through the bot so
Discord stays the single source of truth.

## Consequences

- One place to grant and one place to revoke. Removing a role closes access
  immediately — an open MDC loses its pages mid-session.
- Access survives a character change, because it is attached to the Discord
  identity, not to a character's job field.
- A dismissal in Discord is complete by itself. Nobody has to remember a second
  system.
- **Discord becomes a dependency of access**, so its outage behavior must be
  decided rather than discovered. Spec 4.2 does decide it: a snapshot older than
  15 minutes blocks sensitive actions (approvals, releases, deletions,
  intelligence, surveillance); older than 6 hours drops to read-only. Degrade
  toward less access, never toward more.
- The bot's own role must sit above every role it manages, or role actions fail
  at runtime. This is a deployment requirement, not a code concern.
- A player with no Discord identifier gets no access and an instruction to link
  their account.

## Alternatives considered

**Framework job grades.** Already present and needs no bot. But it splits
revocation across two systems, does not model compartments or DOJ roles, and
ties access to a character rather than a person.

**FredPD's own permission tables as the source.** Full control, at the cost of
building user administration that Discord already provides and that staff
already use. The roster still exists in FredPD — it just maps to Discord roles
rather than competing with them.

**Both, with either granting.** The worst option: access outlives a dismissal
whenever someone updates only one of the two.
