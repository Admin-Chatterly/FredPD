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
    'fpd_intel_persons',
    'fpd_intel_orgs',
    'fpd_intel_notes',
    'fpd_intel_cases',

    -- Migration 0002. Without these listed, a server that applied 0001 and
    -- stopped boots clean and reports every table present, then fails on the
    -- first evidence call with a raw SQL error naming a table the operator has
    -- never heard of. Printing which migration is missing is the entire job of
    -- this check.
    'fpd_biometrics',
    'fpd_weapon_signatures',
    'fpd_scenes',
    'fpd_scene_entries',
    'fpd_evidence',
    'fpd_evidence_owner',
    'fpd_custody_log',
    'fpd_lab_requests',
    'fpd_lab_analyses',
    'fpd_forensic_index',

    -- Migration 0005. `fpd_counters` is the one the whole server needs rather
    -- than one module: every record number in the suite is allocated from it,
    -- so a server missing it cannot open a scene, collect an item or create a
    -- person, and would report each of those as its own unrelated SQL error.
    'fpd_counters',

    -- Record-level access (spec 4.5). The access module is loaded before every
    -- module that reads a record, so these are missing for exactly as long as
    -- access control is not being enforced.
    'fpd_compartments',
    'fpd_classifications',
    'fpd_record_compartments',
    'fpd_record_grants',
    'fpd_record_seals',
    'fpd_breakglass',

    -- M2 records (spec 7.2-7.5).
    'fpd_persons',
    'fpd_person_aliases',
    'fpd_person_descriptors',
    'fpd_person_photos',
    'fpd_person_cautions',
    'fpd_person_biometrics_index',
    'fpd_vehicles',
    'fpd_vehicle_plates',
    'fpd_vehicle_flags',
    'fpd_firearms',
    'fpd_firearm_events',
    'fpd_query_log',

    -- Migration 0006. Hot-file hit confirmation (spec 7.2): the record of
    -- whether a lead was confirmed before an officer acted on it.
    'fpd_hotfile_confirmations',

    -- Migration 0007. Dispatch (spec 7.16-7.18). Listed in full rather than by
    -- `fpd_calls` alone, because a half-applied dispatch migration fails in the
    -- middle of a call rather than at boot: a dispatcher creates a P1, assigns
    -- a unit, and the assignment is the statement that finds `fpd_call_units`
    -- missing -- with the call already on the board and an officer already
    -- driving.
    'fpd_beats',
    'fpd_calls',
    'fpd_call_units',
    'fpd_call_log',
    'fpd_call_links',
    'fpd_units',
    'fpd_broadcasts',
    'fpd_hotlist',
    'fpd_alpr_reads',

    -- Migration 0008. Brottskatalogen (spec 7.10). Listed because every module
    -- that writes a charge resolves it against this table: a server missing it
    -- opens perfectly well and then fails on the first offence anybody tries to
    -- add to an anmälan, which is the point at which an incident is already
    -- half-written.
    'fpd_brott',

    -- Migration 0009. Anmälan och förundersökning (spec 7.7, 7.8). Listed in
    -- full for the reason the dispatch tables are: a half-applied migration
    -- fails in the middle of writing a report rather than at boot, with the
    -- incident already half-typed.
    'fpd_forundersokning',
    'fpd_anmalan',
    'fpd_anmalan_brott',
    'fpd_anmalan_personer',
    'fpd_anmalan_versions',

    -- Migration 0010. Frihetsberövande (spec 7.9). The statutory deadlines are
    -- computed from columns in these, so a server missing them cannot answer
    -- how long it has been holding somebody.
    'fpd_frihetsberovande',
    'fpd_frihet_brott',
    'fpd_frihet_log',

    -- Migration 0011. Tvångsmedel och efterlysning (spec 7.12, 7.13). Listed
    -- because `HasSearchWarrant` (spec 14) reads the first of them: a server
    -- missing it answers every door script `false` and locks the department
    -- out of its own raids with no error anywhere.
    'fpd_tvangsmedel',
    'fpd_efterlysning',

    -- Migration 0012. Spaningsuppdrag (spec 7.13), and the widened hot-file
    -- confirmation constraints.
    'fpd_spaning',
}

--- Columns a migration added to a table that already existed, which the table
--- check above cannot see. One entry per such migration.
local REQUIRED_COLUMNS <const> = {
    -- 0003: which Discord role or permission group opens a fleet vehicle.
    { table = 'fpd_fleet', column = 'required_group' },
    { table = 'fpd_fleet', column = 'required_discord_role' },

    -- 0004: optimistic locking for the permission group editor.
    { table = 'fpd_permission_groups', column = 'version' },

    -- 0024: the payment due date a citation's overdue state is read from.
    { table = 'fpd_ordningsbot', column = 'due_at' },
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

    -- Discord first, because it is the only thing that grants anything
    -- (invariant 2). A server without it starts and grants nobody anything,
    -- which is confusing enough to be worth refusing over in production.
    if config.discord.token == '' then
        faults[#faults + 1] =
            'config/server.lua: discord.token is empty. Discord roles are the only permission source, so nobody will have any access.'
    end

    if config.discord.guildId == '' then
        faults[#faults + 1] =
            'config/server.lua: discord.guildId is empty.'
    end

    if config.agency.id == '' or config.agency.name == '' then
        faults[#faults + 1] =
            'config/server.lua: agency.id and agency.name are what setup creates your agency from.'
    end

    -- Only a gateway that is switched on needs a secret. It is off by default
    -- and FXServer never calls it, so requiring one would be refusing to start
    -- over a service that does nothing (ADR-010).
    if config.gateway.enabled and config.gateway.secret == '' then
        faults[#faults + 1] =
            'config/server.lua: gateway.enabled is true but gateway.secret is empty. Generate one with `openssl rand -hex 32`.'
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

    -- The two forensics bridges (spec 3.8, 8.3.2). Both degrade rather than
    -- refusing to start, and both are worth a line in the console even so: a
    -- server missing them comes up looking healthy and then generates no
    -- casings, no magazines and no tool marks, and leaves a fingerprint where
    -- it should have left a glove mark. That is a silent, whole-milestone
    -- failure, and the warning these print is the only place it is visible.
    FredPD.Bridge.inventory.verify()
    FredPD.Bridge.appearance.verify()

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
    FredPD.Core.db.verifyColumns(REQUIRED_COLUMNS)

    FredPD.Core.agencies.reload()
    FredPD.Core.perms.reload()
    FredPD.Core.placements.reload()

    -- The BOLO cache `garage.plateEvent` reads (spec 3.5.1, ADR-013): seeded
    -- here from the database once, the same way the three reloads above are,
    -- because `cad/service.lua` holds no natives and no database on purpose
    -- and a public route may never reach a record directly.
    do
        local flags = FredPD.Repo.cad.liveBoloFlags()

        for index = 1, #flags do
            FredPD.Modules.cad.boloMark(flags[index].plate, flags[index])
        end
    end

    print(('[fredpd] %s started (env=%s, locale=%s, routes=%d)'):format(
        FredPD.version, FredPD.env(), FredPD.lang, #FredPD.Core.route.names()
    ))

    -- Roles first, then tell the operator what to do about an empty install --
    -- so the instructions are the last thing in the console rather than buried
    -- under the first sync.
    FredPD.Core.discord.start()
    -- A no-op when the gateway is off (ADR-010, spec 3.7's own default).
    FredPD.Bridge.gateway.service.start()
    FredPD.Modules.bootstrap.announce()
end)

--- Refresh a connecting player's roles before they are in a position to open
--- anything, so a role granted a moment ago is already in effect (spec 4.2).
---
--- Deliberately not deferred: a failure here must not keep anybody out of the
--- server. It leaves their stored roles as they were, and the staleness policy
--- decides what that is worth.
AddEventHandler('playerConnecting', function()
    local src = source
    local discordId = FredPD.Bridge.framework.getDiscordId(src)

    if not discordId then return end

    CreateThread(function()
        FredPD.Core.discord.refreshOne(discordId)
    end)
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

    -- `FredPD.Core.session` can be momentarily unset around a resource
    -- restart or a mid-session script refresh, and this event fires from
    -- whatever the client already has queued the instant its own scripts come
    -- back up -- exactly the moment that window is open. Doing nothing is the
    -- safe direction: the client asks again once it reconnects to a session
    -- that exists, and pushing nothing is a no-op, never a leak.
    if not FredPD.Core.session or not FredPD.Core.session.get(src) then return end

    FredPD.Core.placements.pushTo(src)
end)

--- Discord roles changed: re-read the map and redraw every open session's rail
--- (spec 4.2).
---
--- Called by the sync in `core/discord.lua` after a successful refresh, and by
--- the admin screen after the role map is edited. Not a route: no client is
--- involved, and nothing here takes input.
function FredPD.onDiscordChange()
    -- Called from the sync loop's own timer (`core/discord.lua`), which ticks
    -- for as long as the resource runs and does not know or care whether
    -- `Core` has fully come back up around a restart. Skipping this pass
    -- rather than throwing costs nothing: the next successful sync calls it
    -- again `refreshMinutes` later, and until then sessions keep the
    -- permissions they already had.
    if not FredPD.Core.perms or not FredPD.Core.session then return end

    FredPD.Core.perms.reload()
    FredPD.Core.session.refreshAll()
end
