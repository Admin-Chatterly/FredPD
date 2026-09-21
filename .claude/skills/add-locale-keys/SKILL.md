---
name: add-locale-keys
description: Add or change user-facing text in FredPD, in English and Swedish. Use whenever a new string appears in the NUI or in Lua.
---

# Adding locale keys

Invariant 6: no hardcoded user-facing text, and `en` and `sv` are both complete
before a pull request merges. Read spec **section 5** and **Appendix A**.

## Where

`resources/[fredpd]/fredpd/locales/en.json` and `sv.json`. One pair of files
serves both the game and the NUI — the Lua loader and the NUI import the same
JSON, so they cannot drift.

## Naming

Nested by area, lower camelCase leaves: `shell.status.onDuty`,
`records.person.searchPlaceholder`, `error.forbidden`. The key says where the
string lives, not what it says — renaming the wording should not rename the key.

## Rules

- Add to **both** files in the same edit. A key in one and not the other fails
  CI, and rightly so: a half-translated interface ships in whichever language
  the player did not choose.
- Placeholders are **named**, never positional: `{callsign}`, `{name}`. The same
  placeholder names must appear in both languages — `{callsign}` in `en` and
  `{enhet}` in `sv` renders a literal brace in game. `pnpm i18n:check` catches it.
- Never build a sentence by concatenation. Word order differs between the two
  languages; put the whole sentence in the value.
- Never put a number or a date into the string yourself — format it through the
  locale.

## Swedish

Use Appendix A, and prefer the real Swedish police term over a literal
translation:

| English | Svenska |
| --- | --- |
| Report (offence) | Anmälan |
| Call (incident) | Händelse |
| Unit | Enhet |
| Callsign | Anropssignal |
| Field supervisor | Yttre befäl |
| Dispatch center | Ledningscentral |

Swedish runs longer than English — check it fits at MDC width.

Where Swedish legal procedure has no equivalent for a US concept, use the
nearest real Swedish concept and flag it in the pull request rather than
inventing a term.

## Before you finish

`pnpm i18n:check`, then the `i18n-reviewer` subagent for anything beyond a
single obvious string.
