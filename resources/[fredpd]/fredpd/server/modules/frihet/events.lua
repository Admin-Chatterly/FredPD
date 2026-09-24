--- Custody deadline warnings (spec 7.9).
---
--- RB 24:12 and 24:13 are hard limits, and missing one is the kind of mistake
--- a real agency is sued for. The screen already counts down; this tells the
--- officers who have to act while the MDT is shut: the arresting officer, and
--- whoever holds the decision the deadline waits on. Once per chain and
--- deadline, an hour out.
---
--- Reads through the repo and decides in the service; the only thing this file
--- adds is the timer and the memory of what it already said.

local repo = FredPD.Repo.frihet
local service = FredPD.Modules.frihet
local access = FredPD.Repo.access

--- The record type custody chains are known by in the access tables (4.5).
local FRIHET <const> = 'arrest'

--- How often to look, and how far ahead to warn.
local INTERVAL_MS <const> = 5 * 60 * 1000
local WINDOW_SECONDS <const> = 60 * 60

--- Which decision each deadline waits on.
local DECIDER <const> = {
    framstallan = 'frihet.anhallande',
    forhandling = 'frihet.haktning',
}

--- `id:key` -> true, for a warning already sent. In memory: a restart inside
--- the hour repeats one warning, which is the cheap direction to be wrong in.
local warned = {}

local function warn(agencyId, row, key)
    local params = {
        number = row.number,
        deadline = FredPD.t('frihet.deadline.' .. key),
    }

    -- The arresting officer and whoever holds the decision, in this agency,
    -- and only a session that may read the chain: a sealed or compartmented
    -- one is not announced to anybody it is closed to.
    FredPD.Core.push.notifyWhere(function(session)
        return session.agencyId == agencyId
            and (session.discordId == row.gripenBy
                or FredPD.Core.perms.satisfies(session.permissions, DECIDER[key]))
            and access.mayBeToldOf(session, FRIHET, row)
    end, 'frihet.notify.deadline', params, { type = 'error' })
end

local function pass()
    local agencyId = FredPD.Config.server.agency.id
    local now = os.time()
    local offset = service.offsetFromSetting(FredPD.Config.shared.timezoneOffset)
    local rows = repo.open(agencyId, 500) or {}
    local kept = {}

    for index = 1, #rows do
        local row = rows[index]
        local due = service.deadlinesDueWithin(row, now, offset, WINDOW_SECONDS)

        for position = 1, #due do
            local mark = row.id .. ':' .. due[position]

            if not warned[mark] then warn(agencyId, row, due[position]) end
            kept[mark] = true
        end
    end

    -- Only what is still inside a window, so the memory never outgrows the
    -- chains currently open.
    warned = kept
end

CreateThread(function()
    while true do
        Wait(INTERVAL_MS)

        local ok, err = pcall(pass)
        if not ok then print(('[fredpd] frihet deadline pass failed: %s'):format(tostring(err))) end
    end
end)
