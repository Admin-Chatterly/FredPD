--- Police job bridge: p_policejob (spec 3.11, ADR-008).
---
--- FredPD does not replace the police job resource. p_policejob keeps duty,
--- armory, cloakroom and impound; FredPD owns records, dispatch, evidence and
--- the MDT.
---
--- Everything read here is a **context condition** (spec 4.3). A p_policejob
--- rank grants nothing in FredPD -- permissions come from Discord roles and
--- only from Discord roles (invariant 2). This file exists to answer "is this
--- officer on duty right now", never "may this officer approve a report".

FredPD = FredPD or {}
FredPD.Bridge = FredPD.Bridge or {}

local PoliceJob = {}

local RESOURCE <const> = 'p_policejob'

--- Vehicle classes the agency owns. Used only for the `inAgencyVehicle`
--- context condition, so a wrong answer restricts access rather than widening it.
local AGENCY_VEHICLE_CLASS <const> = 18 -- Emergency

local function available()
    return GetResourceState(RESOURCE) == 'started'
end

--- Calls an export, returning nil rather than erroring when it is absent.
---
--- p_policejob's export surface varies between versions and forks, so a missing
--- export must degrade to "unknown" instead of taking down the route that asked.
local function tryExport(name, ...)
    if not available() then return nil end

    local ok, result = pcall(function(...)
        return exports[RESOURCE][name](nil, ...)
    end, ...)

    if not ok then return nil end
    return result
end

--- Where duty is read (ADR-025). pScripts keeps duty in its job core, not in
--- p_policejob: `isPlayerOnDuty(identifier)` there, keyed by the character
--- identifier. `config/server.lua`'s `duty` names another resource that takes
--- the same call.
local function dutyConfig()
    local config = FredPD.Config and FredPD.Config.server and FredPD.Config.server.duty or {}
    return {
        resource = config.resource or 'piotreq_jobcore',
        export = config.export or 'isPlayerOnDuty',
    }
end

--- An export's answer read as on or off duty, or nil when it said neither.
local function asDuty(value)
    if type(value) == 'boolean' then return value end
    if type(value) == 'number' then return value ~= 0 end
    return nil
end

--- Every duty source this server has, in the order they are asked, each with
--- what it answered: `true`, `false`, or nil for "cannot say".
---
---   1. the job core (`duty.resource`, piotreq_jobcore by default), by the
---      character identifier;
---   2. p_policejob's own `isOnDuty`, on a version that has one;
---   3. ESX's `job.onDuty` (ESX Legacy 1.10+);
---   4. the flag FredPD sets where sign-on is configured to.
---
--- @return table list of { source, onDuty }
function PoliceJob.dutySources(src)
    local character = FredPD.Bridge.framework.getCharacter(src)
    local config = dutyConfig()
    local answers = {}

    local core = nil
    if character and character.identifier and GetResourceState(config.resource) == 'started' then
        local ok, result = pcall(function()
            return exports[config.resource][config.export](nil, character.identifier)
        end)
        if ok then core = asDuty(result) end
    end
    answers[#answers + 1] = { source = config.resource, onDuty = core }

    answers[#answers + 1] = { source = RESOURCE, onDuty = asDuty(tryExport('isOnDuty', src)) }
    answers[#answers + 1] = { source = 'esx_job', onDuty = character and character.jobOnDuty }
    answers[#answers + 1] = { source = 'fredpd', onDuty = character and character.onDuty or nil }

    return answers
end

--- Is this officer on duty? The first source that can say decides.
---
--- Unknown counts as off duty. A context condition that fails open would let a
--- duty requirement be satisfied by breaking the thing that answers it.
--- @param src number
--- @return boolean
--- @return string|nil the source that decided
function PoliceJob.isOnDuty(src)
    for _, answer in ipairs(PoliceJob.dutySources(src)) do
        if answer.onDuty ~= nil then return answer.onDuty == true, answer.source end
    end

    return false, nil
end

--- The officer's rank in the police job, for display and context only.
--- @return string|nil
function PoliceJob.getRank(src)
    local character = FredPD.Bridge.framework.getCharacter(src)
    if not character then return nil end

    return tostring(character.grade)
end

--- Is the player sitting in an agency vehicle? (Context condition for the MDC.)
function PoliceJob.isInAgencyVehicle(src)
    local ped = GetPlayerPed(src)
    if ped == 0 then return false end

    local vehicle = GetVehiclePedIsIn(ped, false)
    if not vehicle or vehicle == 0 then return false end

    return GetVehicleClass(vehicle) == AGENCY_VEHICLE_CLASS
end

--- Impound state for a plate, so a vehicle record can show it and link to it.
---
--- Impound itself stays with p_policejob (ADR-008): FredPD reads, and does not
--- write, this. Returns nil when the resource cannot answer, which the caller
--- shows as "unknown" rather than "not impounded" -- the two are different.
function PoliceJob.getImpound(plate)
    return tryExport('getImpoundByPlate', plate)
end

--- Sends somebody to jail (spec 7.20, ADR-017), through the export named in
--- `config/server.lua`'s `jail` -- p_policejob's `JailPlayer(source, data)` by
--- default. `source` is who jails them: the domare who entered the verdict
--- when they are on, otherwise the person themselves (a sentence handed over
--- when they next load in, with no officer present).
---
--- @param target number the prisoner's server id
--- @param minutes number
--- @param reason string plain text, shown by the jail
--- @param jailer number|nil
--- @return boolean|nil true sent; false the call failed; nil no jail here
function PoliceJob.jail(target, minutes, reason, jailer)
    if not PoliceJob.jailAvailable() then return nil end

    local config = FredPD.Config.server.jail or {}
    local resource = config.resource or RESOURCE
    local export = config.export or 'JailPlayer'

    local ok, err = pcall(function()
        return exports[resource][export](nil, jailer or target, {
            player = target, jail = minutes, fine = 0, reason = reason,
        })
    end)

    -- A call that did not throw but answered `false` refused the prisoner
    -- (a jailer check, say): that is a failure, and the sentence is kept for
    -- the next attempt rather than marked served.
    if not ok or err == false then
        print(('[fredpd] jail bridge: %s:%s did not jail (%s) -- check `jail` in config/server.lua')
            :format(resource, export, tostring(err)))
        return false
    end

    return true
end

--- Is there a jail to hand a sentence to right now?
function PoliceJob.jailAvailable()
    local config = FredPD.Config.server.jail or {}
    if config.enabled == false then return false end

    return GetResourceState(config.resource or RESOURCE) == 'started'
end

--- Startup check (spec 3.8).
---
--- A missing p_policejob is a warning, not a fatal error: FredPD's own modules
--- work without it, and every context condition it answers fails closed. Saying
--- so loudly at boot beats discovering it when nobody can go on duty.
function PoliceJob.verify()
    local core = dutyConfig().resource
    if GetResourceState(core) ~= 'started' then
        print(('[fredpd] policejob bridge: %s is not started, so duty is read from ESX (job.onDuty) '
            .. 'instead. If nobody can go on duty, run `fredpd_duty <server id>` in the console.'):format(core))
    end

    if not available() then
        print(('[fredpd] policejob bridge: %s is not started. Duty and impound context are unavailable; on-duty routes refuse.')
            :format(RESOURCE))
        return false
    end

    return true
end

FredPD.Bridge.policejob = PoliceJob
