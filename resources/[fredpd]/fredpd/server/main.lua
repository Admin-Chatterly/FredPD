--- Boot for the core resource.
---
--- M0 scope: come up cleanly, or refuse to come up and say exactly why. The
--- route layer, session service, permissions and modules land in M1 under
--- `server/core/` and `server/modules/`.

local REQUIRED_RESOURCES <const> = { 'ox_lib', 'oxmysql', 'es_extended' }

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
    FredPD.Bridge.framework.verify()

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

    print(('[fredpd] %s started (env=%s, locale=%s)'):format(FredPD.version, FredPD.env(), FredPD.lang))
end)
