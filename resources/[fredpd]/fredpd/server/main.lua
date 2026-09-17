--- Boot for the core resource.
---
--- Come up cleanly, or refuse to come up and say exactly why.

local REQUIRED_RESOURCES <const> = { 'ox_lib', 'oxmysql', 'es_extended' }

--- Tables the server cannot function without. Checked once at boot so a server
--- started against an unmigrated database fails here, with a clear message,
--- rather than one confusing query at a time (spec 16).
local REQUIRED_TABLES <const> = {
    'fpd_agencies',
    'fpd_officers',
    'fpd_permission_groups',
    'fpd_group_permissions',
    'fpd_role_map',
    'fpd_discord_members',
    'fpd_audit_log',
    'fpd_placements',
    'fpd_chat_messages',
    'fpd_fleet',
    'fpd_motorpool_log',
}

--- Returns the names of any dependency that is not started.
local function missingResources()
    local missing = {}

    for _, name in ipairs(REQUIRED_RESOURCES) do
        if GetResourceState(name) ~= 'started' then
            missing[#missing + 1] = name
        end
    end

    return missing
end

--- Configuration problems that must stop the resource rather than surface
--- later as a confusing runtime error. Returns a list of human-readable faults.
local function configurationFaults()
    local faults = {}
    local config = FredPD.Config.server

    if config.gateway.secret == '' then
        faults[#faults + 1] =
            'fredpd:gateway_secret is not set. Add `set fredpd:gateway_secret "<secret>"` to server.cfg (use `set`, never `setr`).'
    end

    if FredPD.isProduction() and config.discord.guildId == '' then
        faults[#faults + 1] =
            'fredpd:discord_guild is not set. Discord roles are the only permission source, so production cannot grant anything without it.'
    end

    return faults
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= FredPD.resource then return end

    local missing = missingResources()
    if #missing > 0 then
        error(('[fredpd] missing dependencies: %s. Start them before fredpd.'):format(table.concat(missing, ', ')))
    end

    -- Bridges check the resources they wrap before anything tries to use them.
    -- The framework is required; the rest degrade with a warning (spec 3.8).
    FredPD.Bridge.framework.verify()
    FredPD.Bridge.policejob.verify()
    FredPD.Bridge.society.verify()

    local faults = configurationFaults()
    if #faults > 0 then
        for _, fault in ipairs(faults) do
            print(('[fredpd] configuration: %s'):format(fault))
        end

        -- Development is allowed to run half-configured so the NUI can be worked
        -- on without a gateway. Staging and production are not.
        if FredPD.isProduction() then
            error('[fredpd] refusing to start in production with an incomplete configuration (see the lines above).')
        end
    end

    FredPD.Core.db.verifySchema(REQUIRED_TABLES)

    FredPD.Core.agencies.reload()
    FredPD.Core.perms.reload()
    FredPD.Core.placements.reload()

    print(('[fredpd] %s started (env=%s, locale=%s, routes=%d)'):format(
        FredPD.version, FredPD.env(), FredPD.lang, #FredPD.Core.route.names()
    ))
end)

--- A player asking for their world geometry once they are in the session.
---
--- Placements carry no permission data (ADR-006), so this needs no permission
--- of its own beyond having a session at all.
RegisterNetEvent('fredpd:requestPlacements', function()
    local src = source

    -- Rate limited before the session lookup, not after. A player with no
    -- roster entry never gets a cached session, so every call would otherwise
    -- run a Discord lookup, an ESX lookup and a `fpd_officers` SELECT -- and
    -- any connected player can fire this event in a loop (spec 11.1).
    if not FredPD.Core.ratelimit.take(src, 'requestPlacements', { per = 3, window = 10 }) then
        return
    end

    if not FredPD.Core.session.get(src) then return end

    FredPD.Core.placements.pushTo(src)
end)

--- The gateway tells FXServer that Discord roles changed (spec 4.2, 3.7).
---
--- Registered here rather than as a route because the caller is the gateway over
--- the signed loopback link, not a game client. The HMAC check in the HTTP
--- handler is its authentication; M1 wires that handler to this function.
function FredPD.onDiscordChange()
    FredPD.Core.perms.reload()
    FredPD.Core.session.refreshAll()
end
