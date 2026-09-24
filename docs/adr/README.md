# Architecture decision records

One file per decision, numbered, never rewritten once accepted. A decision that
turns out wrong gets a new ADR that supersedes the old one — the record of
having believed it is part of the value.

Format: context, decision, consequences, alternatives considered.

When a decision changes `docs/FredPD.md`, the ADR and the spec edit go in the
**same pull request** (spec, "How to use this document").

| ADR | Decision | Status |
| --- | --- | --- |
| [001](001-lua-server.md) | Lua 5.4 with ox_lib for server scripts | Accepted |
| [002](002-svelte-nui.md) | Svelte 5 + TypeScript + Vite for the NUI | Accepted |
| [003](003-gateway-service.md) | A separate Node.js gateway service | Accepted |
| [004](004-discord-permissions.md) | Discord roles as the only permission source | Accepted |
| [005](005-esx-framework.md) | ESX as the target framework, behind a bridge | Accepted |
| [006](006-in-game-placement-config.md) | World positions configured in game, not in config files | Accepted |
| [007](007-police-chat-in-game-chat.md) | The internal police channel lives in the game chat | Accepted |
| [008](008-coexist-with-p-policejob.md) | Coexist with p_policejob rather than replacing it | Accepted (impound amended by 016) |
| [009](009-single-baseline-migration.md) | The schema ships as one baseline migration | Accepted |
| [010](010-discord-sync-in-fxserver.md) | Discord role sync runs in FXServer, not in the gateway | Accepted |
| [011](011-evidence-records-live-in-the-core.md) | Evidence records live in the core; satellites hold only in-world mechanics | Accepted |
| [012](012-record-numbers-from-a-locked-counter.md) | Record numbers come from a locked counter row, not from MAX() of the target table | Accepted |
| [013](013-a-public-route-tier.md) | A public route tier, for the actions spec 8.10 gives to every player | Accepted |
| [014](014-swedish-procedure.md) | Swedish procedure, not US workflows with Swedish labels | Accepted |
| [015](015-citations-send-real-bills.md) | A citation sends a real bill through esx_billing, and learns it was paid | Accepted |
| [016](016-impound-reaches-the-street.md) | An impound takes the car off the street and out of the garage (amends ADR-008) | Accepted |
| [017](017-a-verdict-is-served.md) | A verdict is served in the game: the tilltalade is named and handed to the jail | Accepted |
| [018](018-licence-points-and-an-editable-tariff.md) | Licence points on the tariff, and a tariff the agency's command edits | Accepted |
| [019](019-photographs-through-the-gateway.md) | Photographs and mugshots through the gateway: a ledger, re-encoding, links FXServer signs | Accepted |
| [020](020-printed-documents.md) | Printed documents are copies: a paper item carries its own content, a PDF is optional | Accepted |
