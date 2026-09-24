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
  - A superuser passes the last two checks, as everywhere else, and a
    superuser's own roles count as everything, so only a superuser can change
    them.
  - The target is weighed on Discord as it is now. They are read back from
    Discord before the check, and a target with no fresh row is refused
    (`target_stale`). The one exception is a new hire by Discord id, who has
    nothing to outrank anybody with.
  - A role that any other agency maps to a group is refused. The guards only
    weigh a role in the actor's own agency.
  - A session on the ESX-job fallback never drives a role change, and role
    actions are off whenever FredPD is not reading Discord (invariant 2).
- **Every change is a sensitive, audited write.** It is refused on a stale
  snapshot (4.2), needs a reason, and is rate-limited. The reason goes both to
  `fpd_audit_log` (`personnel.role.changed`) and to Discord's own audit log,
  signed with who asked. The reason is cut to Discord's 512 encoded bytes, a
  whole character at a time.
- **Every attempt is audited too.** A refused or failed request writes
  `personnel.role.attempted`, recording the target, the role, the direction,
  the reason and why it stopped. The wrapper's own refusal row records only
  the error code. When the gateway gave no answer, the outcome is recorded as
  unknown and Discord is read back: no answer is not a no.
- **A signed request is honoured once.** The gateway refuses the same signed
  bytes a second time inside the replay window, so a request that added a
  role cannot be replayed to add it back after it was removed.
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
- A role change costs one extra read of the target from Discord, so the
  guard never weighs someone by a snapshot that is out of date.
