--- Server-to-client pushes (spec 3.6, invariant 5).
---
--- The rule this module exists to enforce: a record is never broadcast. There is
--- deliberately no "send to everyone" function here, because the moment one
--- exists somebody uses it for a record.
---
--- Every push either names one session, or names a permission and is delivered
--- only to the sessions that hold it -- filtered through the same check a read
--- would go through (invariant 4).

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Push = {}

--- Sends to one session.
function Push.toSession(src, event, payload)
    TriggerClientEvent(event, src, payload)
end

--- Sends to every session holding `permission`.
---
--- @param permission string
--- @param event string
--- @param payload table
--- @param filter function|nil extra per-session predicate, e.g. same agency
--- @return number recipients
function Push.toPermission(permission, event, payload, filter)
    local sessions = FredPD.Core.session.all()
    local sent = 0

    for src, session in pairs(sessions) do
        if FredPD.Core.perms.satisfies(session.permissions, permission)
            and (not filter or filter(session))
        then
            TriggerClientEvent(event, src, payload)
            sent = sent + 1
        end
    end

    return sent
end

FredPD.Core.push = Push
