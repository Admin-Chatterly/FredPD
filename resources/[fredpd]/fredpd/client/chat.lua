--- Internal police chat, client side (spec 7.26, ADR-007).
---
--- The channel renders in the standard FiveM chat box, so officers read it
--- without opening the MDT. Incoming messages arrive as ordinary
--- `chat:addMessage` events, addressed to this client only — the server decided
--- who gets them.
---
--- The command is registered on the client and calls a route, rather than being
--- a server-side `RegisterCommand`. A server command would be a client-to-server
--- path that skips the route wrapper, and therefore skips the permission check,
--- the rate limit and the audit entry (invariant 3).

FredPD = FredPD or {}
FredPD.Client = FredPD.Client or {}

local COMMAND <const> = 'pd'

RegisterCommand(COMMAND, function(_source, _args, rawCommand)
    -- `args` splits on spaces and loses the original spacing, so take the raw
    -- line minus the command itself.
    local body = rawCommand:sub(#COMMAND + 2)

    if body == nil or body:gsub('%s', '') == '' then
        FredPD.Client.core.notify('chat.usage')
        return
    end

    local response = FredPD.Client.core.call('chat.send', { body = body })

    if not response.ok then
        FredPD.Client.core.showError(response)
    end
end, false)

-- Shows in the chat's own command list. Purely a hint: whether the command does
-- anything is decided by the permission on the server.
TriggerEvent('chat:addSuggestion', '/' .. COMMAND, FredPD.t('chat.suggestion'), {
    { name = 'message', help = FredPD.t('chat.suggestionArg') },
})
