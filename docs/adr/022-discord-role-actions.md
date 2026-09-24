# ADR-022: Discord role actions, through a bot of their own

- **Status:** Accepted
- **Date:** 2026-09-24
- **Spec:** 4.2, 7.22, 3.7, 11
- **Amends:** ADR-010 (FXServer only reads the guild)

## Context

ADR-010 moved the read side of Discord into FXServer and left role actions
(hire, promote, demote, dismiss) unbuilt. The concern was that a resource able
to grant roles would be the permission source contradicting itself. Discord
is the only thing that grants anything in FredPD (invariant 2).

The owner asked for role actions. A command officer would otherwise leave the
game to change a rank in Discord, which is the paperwork this suite exists to
remove. The concern still holds, so this ADR bounds it rather than dismissing
it.

## Decision

- **Discord stays the only permission source.** FredPD asks Discord to change
  one role. It never writes `fpd_discord_members` and never grants a
  permission itself. The change comes back through the read sync
  (`discord.refreshOne`), and every open session re-derives its grants from it.
- **The gateway does the write, with a bot of its own.** The bot holds only
  Manage Roles. Its token lives only in the gateway's environment, never in
  `config/server.lua`, and it is not the read bot. Its Discord role sits above
  the roles it manages and below every administrator role.
- **Two allowlists, kept separately.**
  - `roleActions.roles` in `config/server.lua` names the roles FredPD offers.
  - `FREDPD_ROLE_ACTIONS_ALLOWED` in the gateway's environment names the only
    roles the gateway will touch.
  - A compromised FXServer or a leaked signing secret can therefore reach at
    most the listed rank roles. It can never reach an administrator role, or
    any role the gateway was not told about.
- **Two kinds of role, two permissions.**
  - `hire` makes somebody an employee; hiring and dismissing need
    `personnel.hire`.
  - `rank` is a rung of the ladder; promoting and demoting need
    `personnel.promote`.
  - Each is its own route (`personnel.roles.hire`, `personnel.roles.rank`), so
    the route says what it needs.
  - The seed grants both to `command`.
- **Guards** (`personnel/service.lua` `roleChange`, tested in busted):
  - Nobody changes their own roles, superuser included.
  - A granted role is worth no more than the actor holds (`perms.missing`,
    the same rule the role-map editor applies).
  - The target holds nothing the actor lacks: a supervisor does not demote the
    commander.
  - A superuser passes the last two checks, as everywhere else.
- **Every change is a sensitive, audited write.** It is refused on a stale
  snapshot (4.2), needs a reason, and is rate-limited. The reason goes both to
  `fpd_audit_log` (`personnel.role.changed`) and to Discord's own audit log,
  signed with who asked.
- **Now or not at all.** A role change is never queued in the outbox. A
  promotion that lands an hour after the officer was told it failed is a
  change nobody decided.
- **Hiring somebody not on the roster** is by Discord id, and only for a
  `hire` role. They join the roster on their next connect (phase 0's
  auto-provisioning).
- **Off by default,** on both sides.

## Consequences

- A command officer can manage the rank ladder from the roster, and Discord
  shows who did it and why.
- The operator keeps two lists in step. A role in only one list is refused:
  by the NUI if it is missing from config, and by the gateway if it is missing
  from its allowlist. Neither failure grants anything.
- The escalation guard reads the target's roles from the last sync. A role
  granted in Discord seconds ago may not count yet. That errs toward refusing,
  never toward allowing.
