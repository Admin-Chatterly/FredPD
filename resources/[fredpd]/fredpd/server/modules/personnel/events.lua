--- Personnel: what this module does in response to the rest of the suite
--- (spec 14, 7.22).
---
--- Server-local only (`AddEventHandler`, never `RegisterNetEvent`) -- a net
--- event here would let a client issue or return equipment for any officer
--- by naming them (invariant 3 read backwards).
---
--- `cad/events.lua`'s sign-on poll is the one place in the suite that
--- already knows when duty changes; this listens for what it fires rather
--- than reaching into that module's repo, the identical shape
--- `spaning/events.lua` takes for `fredpd:gripande` and `fredpd:vehicleImpounded`.

AddEventHandler('fredpd:dutyChanged', function(event)
    if type(event) ~= 'table' then return end

    local officerId = tonumber(event.officerId)
    if not officerId then return end

    FredPD.Repo.personnel.applyDutyChange(officerId, event.agencyId, event.discordId, event.working == true)
end)
