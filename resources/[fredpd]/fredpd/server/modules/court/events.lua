--- The verdict reaches the world (spec 7.20, ADR-017).
---
--- `court.disposition.enter` fires `fredpd:sentenced` (server-local, never a
--- client event). Two things follow:
---
---   * **The officers who worked the case are told** -- whoever made an
---     arrest in the investigation, wrote one of its reports, or led it --
---     each only if they may know of the åtal (`mayBeToldOf`). The notice
---     carries the åtal number and nothing else.
---   * **A custodial sentence is served.** The tilltalade is handed to the
---     police job's jail through the policejob bridge: at once if they are
---     on, otherwise the next time their character loads. A sentence is
---     claimed before the jail is called and the claim released if the call
---     fails, so two logins in a row never jail somebody twice and a jail
---     that was down does not lose the sentence.

FredPD.Modules = FredPD.Modules or {}

local repo = FredPD.Repo.court

local Events = {}

--- Hands one sentence to the jail, if the person is on. Returns true when it
--- was handed over.
function Events.serve(atalId, agencyId, number, minutes, jailer)
    local identifier = repo.identifierFor(atalId, agencyId)
    if not identifier then return false end

    local src = FredPD.Bridge.framework.sourceOf(identifier)
    if not src then return false end

    -- No jail running: leave the sentence unclaimed and unaudited, for the
    -- next login, rather than an error row on every one.
    if not FredPD.Bridge.policejob.jailAvailable() then return false end

    if repo.claimJail(atalId) == 0 then return false end

    local sent = FredPD.Bridge.policejob.jail(src, minutes,
        FredPD.t('court.jail.reason', { number = number }), jailer)

    if sent ~= true then repo.releaseJailClaim(atalId) end

    FredPD.Core.audit.write({
        action = 'court.jailed',
        agencyId = agencyId,
        subjectType = 'case',
        subjectId = tostring(atalId),
        outcome = sent == true and 'ok' or 'error',
        detail = { minutes = minutes, jail = sent == nil and 'unavailable' or nil },
    })

    return sent == true
end

--- Tells the officers who worked the case how it ended.
function Events.tellWorkers(row)
    local told = {}
    for _, discordId in ipairs(FredPD.Repo.anmalan.fuArresters(row.fuId, row.agencyId)) do
        told[discordId] = true
    end

    FredPD.Core.push.notifyWhere(function(other)
        return other.agencyId == row.agencyId and told[other.discordId] == true
            and FredPD.Repo.access.mayBeToldOf(other, 'case', row)
    end, 'court.notify.' .. tostring(row.disposition), { number = row.number }, { type = 'inform' })
end

AddEventHandler('fredpd:sentenced', function(event)
    if type(event) ~= 'table' then return end

    local row = repo.byId(event.atalId, event.agencyId)
    if not row or not row.disposition then return end

    Events.tellWorkers(row)

    if row.jailMinutes and row.jailMinutes > 0 then
        Events.serve(row.id, row.agencyId, row.number, row.jailMinutes, event.judgeSrc)
    end
end)

--- A sentence handed down while the person was away is served when they
--- come back. A few seconds' grace, so the jail meets a character that has
--- finished loading rather than one still spawning.
FredPD.Bridge.framework.onCharacterLoaded(function(src, identifier)
    -- ESX fires this server-side only; checked anyway, so a character is
    -- only ever served as the player actually holding it.
    if FredPD.Bridge.framework.sourceOf(identifier) ~= src then return end

    CreateThread(function()
        Wait(5000)

        for _, row in ipairs(repo.unservedFor(identifier)) do
            Events.serve(row.id, row.agencyId, row.number, row.jailMinutes, nil)
        end
        -- The source is looked up again inside `serve`, so a player who
        -- dropped during the grace is simply not found, and it waits for
        -- their next login.
    end)
end)

FredPD.Modules.courtEvents = Events
