--- Forensics resource namespace.
---
--- Scope (spec 8, milestone M3): evidence generation, scene processing,
--- packaging and destruction mechanics.
---
--- Forensic truth -- whose print it is, whose blood, which weapon fired a
--- casing -- is decided and stored on the server and never sent to a client
--- (invariants 1 and 5). Clients see an unidentified item until the lab
--- reports a result to someone authorized to read it.

FredPDForensics = FredPDForensics or {}

FredPDForensics.resource = GetCurrentResourceName()
FredPDForensics.version = GetResourceMetadata(FredPDForensics.resource, 'version', 0) or '0.0.0'

-- -----------------------------------------------------------------------------
-- Translation (invariant 6, spec 5.1)
-- -----------------------------------------------------------------------------

--- Every user-facing string in this resource is a key in the core's locale
--- files, because there is one set of locale files and `pnpm i18n:check` reads
--- them (invariant 6, spec 5.4). FiveM gives this resource its own Lua state, so
--- the core's loader has to be loaded into it -- `fxmanifest.lua` lists
--- `@fredpd/config/shared.lua` and `@fredpd/shared/locale.lua` after this file.
---
--- The loader reads `locales/<lang>.json` out of `FredPD.resource`, which in
--- this state would otherwise be this resource's own name and would find
--- nothing. Naming the core here is what makes it read the core's files; it is
--- not a bridge in the sense of spec 3.8 (this resource already depends on
--- `fredpd` in its manifest, and a satellite that could not name its core would
--- have nothing to talk to).
FredPD = FredPD or {}
FredPD.resource = 'fredpd'

--- A translation function before the real one loads, so a mis-ordered manifest
--- degrades to visible keys in game rather than a nil call in a prompt. The
--- loader replaces it a moment later; both answer the key itself when a key is
--- missing, which is what makes a missing translation obvious (spec 5.2).
if type(FredPD.t) ~= 'function' then
    FredPD.t = function(key) return key end
end
