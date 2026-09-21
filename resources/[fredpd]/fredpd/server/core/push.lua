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

--- Sends every session holding `permission` a payload built for that session.
---
--- `toPermission` above sends one payload to a list of recipients, which is the
--- right shape whenever the access question has one answer for the whole
--- message: the CAD unit push carries exactly one call, so the recipients
--- divide into the ones who may read it and the ones who may not, and two
--- complementary `toPermission` calls cover everybody exactly once.
---
--- That trick stops working the moment one payload carries **several** records
--- with different answers -- a welfare prompt listing units on half a dozen
--- calls, say. There is no split of the recipients that is right for a reader
--- cleared for one of those calls and not another: one payload discloses what
--- they were refused, and any two-way split has no half that fits them. So the
--- payload is built per recipient instead, after the permission and the
--- caller's own filter have both said yes -- which keeps the cost off the
--- sessions that were never going to be sent anything.
---
--- `build` returning nil skips that session and does not count it, so "this
--- recipient has nothing left to be told once the masking is done" is a case
--- the caller can express without a second filter.
---
--- @param permission string
--- @param event string
--- @param build function (session) -> table|nil the payload for that session
--- @param filter function|nil extra per-session predicate, e.g. same agency
--- @return number recipients
function Push.perSession(permission, event, build, filter)
    local sessions = FredPD.Core.session.all()
    local sent = 0

    for src, session in pairs(sessions) do
        if FredPD.Core.perms.satisfies(session.permissions, permission)
            and (not filter or filter(session))
        then
            local payload = build(session)

            if payload ~= nil then
                TriggerClientEvent(event, src, payload)
                sent = sent + 1
            end
        end
    end

    return sent
end

FredPD.Core.push = Push
