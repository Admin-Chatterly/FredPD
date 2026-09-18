--- Spaningsuppdrag: what this module does in response to the rest of the suite
--- (spec 7.13, 14).
---
--- Server-local events only (`AddEventHandler`, never `RegisterNetEvent`). A
--- net event here would let a client resolve every lookout on the server by
--- naming a target, which is invariant 3 read backwards.

--- Records what a cascade took down.
---
--- Deliberately not scoped by agency (the van has been found), which makes it
--- the widest-reaching write here and the one that most needs a line in the
--- log. Spec 11.2: an entry for every sensitive action. One row per cascade,
--- carrying the count -- which is what somebody reviewing the gripande needs.
local function auditCascade(event, targetKind, targetId, resolved)
    if (resolved or 0) == 0 then return end

    FredPD.Core.audit.write({
        action = 'spaning.auto_resolved',
        discordId = event.discordId,
        agencyId = event.agencyId,
        subjectType = 'spaning',
        subjectId = tostring(targetId),
        detail = { targetKind = targetKind, targetId = targetId, resolved = resolved },
    })
end

--- 7.13: "auto-resolve on arrest or impound".
---
--- The thing being looked for has turned up, so the lookout has done its job.
--- Left live, it would keep raising a banner for a person already in a cell --
--- and an officer who is sent after somebody twice stops reading the banners.
---
--- **Across every agency**, unlike most reads in this suite: the van has been
--- found, and a second department's lookout for it is exactly as stale as the
--- first's.
AddEventHandler('fredpd:gripande', function(event)
    if type(event) ~= 'table' then return end

    local personId = tonumber(event.personId)
    if not personId then return end

    local resolved = FredPD.Repo.spaning.resolveForTarget(
        'person', personId, event.discordId, 'spaning.grund.gripen')

    auditCascade(event, 'person', personId, resolved)
end)

--- The vehicle half of the same rule.
---
--- Fired by whatever takes a vehicle in. The impound module is M6, so nothing
--- raises this yet -- the handler exists now because the event name is the
--- contract, and a module that declares what it reacts to before the emitter
--- exists is easier to wire up than one that has to be found later.
AddEventHandler('fredpd:vehicleImpounded', function(event)
    if type(event) ~= 'table' then return end

    local vehicleId = tonumber(event.vehicleId)
    if not vehicleId then return end

    local resolved = FredPD.Repo.spaning.resolveForTarget(
        'vehicle', vehicleId, event.discordId, 'spaning.grund.omhandertaget')

    auditCascade(event, 'vehicle', vehicleId, resolved)
end)
