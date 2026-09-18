--- Tvångsmedel och efterlysning: what this module does in response to the rest
--- of the suite (spec 7.13, 14).
---
--- Server-local events only (`AddEventHandler`, never `RegisterNetEvent`). A
--- net event here would be a client able to cancel every efterlysning on the
--- server by naming a person id, which is invariant 3 read backwards.

--- Records what a cascade took down.
---
--- These UPDATEs are deliberately not scoped by agency -- the person is in a
--- cell, and another department's wanted notice for them is as stale as this
--- one's. That makes them the widest-reaching writes in the suite, and until
--- now the only thing in the log was the gripande itself: nothing said which
--- notices had been cancelled, or how many, or across which agencies.
---
--- Spec 11.2 wants an entry for every sensitive action. One row per cascade
--- rather than one per notice: the gripande is the act, and the count is what
--- somebody reviewing it needs.
local function auditCascade(event, personId, cancelled)
    if (cancelled or 0) == 0 then return end

    FredPD.Core.audit.write({
        action = 'efterlysning.auto_cancelled',
        discordId = event.discordId,
        agencyId = event.agencyId,
        subjectType = 'efterlysning',
        subjectId = tostring(personId),
        detail = { personId = personId, cancelled = cancelled, frihetId = event.frihetId },
    })
end

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

    local cancelled = FredPD.Repo.tvangsmedel.cancelForPerson(
        personId, event.discordId, 'efterlysning.grund.gripen')

    auditCascade(event, personId, cancelled)
end)
