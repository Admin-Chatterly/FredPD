--- Internal police chat routes (spec 7.26, ADR-007).

local route = FredPD.Core.route
local service = FredPD.Modules.chat
local repo = FredPD.Repo.chat

--- Permission check in the shape the service wants, so the service itself stays
--- free of any dependency on how permissions are stored.
local function hasPermission(session, permission)
    return FredPD.Core.perms.satisfies(session.permissions, permission)
end

route.define({
    name = 'chat.send',
    perm = 'comms.pdchat.send',
    schema = 'ChatSend',
    -- Tighter than the default: this route writes to a chat box shared with
    -- every other resource, so it is the easiest thing in FredPD to spam.
    limit = { per = 8, window = 10 },
    handler = function(session, input)
        local body = service.sanitize(input.body)
        if not body then
            return route.refuse(FredPD.ErrorCode.INVALID, { body = 'empty' })
        end

        repo.insert(session, body)

        local payload = service.format(session, body)

        -- The recipient list is computed here, per message, and the message is
        -- delivered only to sessions that pass. It is never broadcast, even
        -- though every player has the same chat box open (invariant 5).
        local sessions = FredPD.Core.session.all()
        local delivered = 0

        for src, recipient in pairs(sessions) do
            if service.canReceive(recipient, session.agencyId, hasPermission) then
                TriggerClientEvent('chat:addMessage', src, payload)
                delivered = delivered + 1
            end
        end

        return { delivered = delivered }
    end,
})

route.define({
    name = 'chat.history',
    perm = 'comms.pdchat.view',
    schema = 'ChatHistory',
    handler = function(session, input)
        return { messages = repo.recent(session.agencyId, input.limit or 50) }
    end,
})
