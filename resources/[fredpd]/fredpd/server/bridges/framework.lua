--- Framework bridge: ESX (es_extended).
---
--- Spec 3.8. Bridges are the only place that names another resource, so when
--- the server swaps framework this file is the diff and nothing else moves.
---
--- What the bridge is allowed to supply: identity and context -- who this
--- player's character is, what job they hold, whether they are on duty.
---
--- What it must never supply: permissions. ESX job grades grant nothing in
--- FredPD (invariant 2). Jobs and duty are only *context conditions* layered on
--- top of a permission that a Discord role already granted (spec 4.3).

FredPD.Bridge = FredPD.Bridge or {}

local Framework = {}

local ESX

--- Resolves the ESX shared object once the resource is up.
local function core()
    if ESX then return ESX end
    if GetResourceState('es_extended') ~= 'started' then return nil end

    ESX = exports['es_extended']:getSharedObject()
    return ESX
end

--- The character behind a server id.
---
--- `identifier` is the ESX character identifier (`char1:license:…` on a
--- multi-character server, the bare licence otherwise). It is the key FredPD
--- binds a roster entry to (spec 4.1).
---
--- @param src number server id
--- @return table|nil character
function Framework.getCharacter(src)
    local esx = core()
    if not esx then return nil end

    local player = esx.GetPlayerFromId(src)
    if not player then return nil end

    return {
        identifier = player.identifier,
        firstName = player.get('firstName') or '',
        lastName = player.get('lastName') or '',
        job = player.getJob().name,
        grade = player.getJob().grade,
        -- ESX has no duty concept of its own; servers model it as a job or a
        -- metadata flag. Treated as context only, never as a grant.
        onDuty = player.get('onDuty') == true,
    }
end

--- Sets duty state, when the server models it (spec 7.1, configurable).
--- Returns false when the server has no duty concept, so the caller can tell
--- "refused" apart from "not applicable".
--- @param src number
--- @param onDuty boolean
--- @return boolean handled
function Framework.setDuty(src, onDuty)
    local esx = core()
    if not esx then return false end

    local player = esx.GetPlayerFromId(src)
    if not player then return false end

    player.set('onDuty', onDuty)
    return true
end

--- The Discord identifier for a player, read on the server and never accepted
--- from a client (invariant 1, spec 4.1).
--- @param src number
--- @return string|nil discordId without the `discord:` prefix
function Framework.getDiscordId(src)
    local identifier = GetPlayerIdentifierByType(src, 'discord')
    if not identifier then return nil end

    return (identifier:gsub('^discord:', ''))
end

--- Startup check (spec 3.8): fail loudly and early, not on first use.
function Framework.verify()
    if GetResourceState('es_extended') ~= 'started' then
        error('[fredpd] framework bridge: es_extended is not started.')
    end

    if not core() then
        error('[fredpd] framework bridge: es_extended is started but did not return a shared object.')
    end
end

FredPD.Bridge.framework = Framework
