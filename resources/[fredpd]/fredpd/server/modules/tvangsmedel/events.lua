--- Tvångsmedel och efterlysning: what this module does in response to the rest
--- of the suite (spec 7.13, 14).
---
--- Server-local events only (`AddEventHandler`, never `RegisterNetEvent`). A
--- net event here would be a client able to cancel every efterlysning on the
--- server by naming a person id, which is invariant 3 read backwards.

--- 7.13: "auto-resolve on arrest".
---
--- The frihetsberövande module announces a gripande; this module decides what
--- that means for the efterlysningar it owns. Structured this way rather than
--- as a call from `frihet/routes.lua` because a module reaches another through
--- its service and never its repo, and cancelling is a write.
---
--- **Every live efterlysning on the person comes down, not only the one that
--- caused the gripande.** An officer who seizes somebody wanted on three
--- grounds has answered all three: the person is in custody, and leaving two
--- banners live would put the next officer on a hunt for somebody sitting in a
--- cell. Where a ground genuinely survives an arrest -- a delgivning that still
--- has to happen -- it is re-issued deliberately, which is a decision somebody
--- makes rather than a state nobody cleared.
AddEventHandler('fredpd:gripande', function(event)
    if type(event) ~= 'table' then return end

    local personId = tonumber(event.personId)
    if not personId then return end

    FredPD.Repo.tvangsmedel.cancelForPerson(
        personId, event.discordId, 'efterlysning.grund.gripen')
end)
