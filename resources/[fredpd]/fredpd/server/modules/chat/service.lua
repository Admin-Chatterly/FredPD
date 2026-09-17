--- Internal police chat logic (spec 7.26, ADR-007).
---
--- Pure: no natives, no database, so busted tests it directly. Worth testing,
--- because this is where a message that reaches the shared chat box is made
--- safe to put there.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Chat = {}

--- Matches fpd_chat_messages.body and the ChatSend schema.
local MAX_BODY <const> = 512

--- Strips anything that would let a sender paint the chat box or forge a prefix.
---
--- FiveM colour codes are `^1`..`^9`; GTA text tokens are `~r~`, `~b~` and so
--- on. Both render in the chat box, so both are removed rather than escaped:
--- there is no legitimate reason for an officer's message to contain them, and
--- leaving either in would let a sender imitate the server-generated prefix.
---
--- @param body string
--- @return string|nil cleaned, nil when nothing usable is left
function Chat.sanitize(body)
    if type(body) ~= 'string' then return nil end

    local cleaned = body
        :gsub('%^%d', '')      -- ^1 .. ^9
        :gsub('~%a+~', '')     -- ~r~, ~b~, ~HUD_COLOUR~ …
        :gsub('[%c]', ' ')     -- newlines and control characters
        :gsub('%s+', ' ')      -- collapse runs of whitespace
        :gsub('^%s*(.-)%s*$', '%1')

    if cleaned == '' then return nil end

    if #cleaned > MAX_BODY then
        cleaned = cleaned:sub(1, MAX_BODY)
    end

    return cleaned
end

--- Builds the line shown in the chat box.
---
--- Every part of the prefix comes from the session, never from the client
--- (invariant 1): an officer cannot post as another callsign because the
--- callsign is not something they send.
---
--- @param session table
--- @param body string already sanitized
--- @return table the chat:addMessage payload
function Chat.format(session, body)
    local who = session.callsign and session.callsign ~= ''
        and ('%s | %s'):format(session.callsign, session.name or '')
        or (session.name or '')

    return {
        -- Muted police blue: readable in the chat box without competing with
        -- OOC or emergency messages.
        color = { 110, 155, 225 },
        multiline = true,
        args = { who, body },
    }
end

--- Should this session receive a message from `sender`?
---
--- Permission alone is not enough: the channel is agency-scoped, so an officer
--- in another department needs `comms.pdchat.all` to see it (spec 7.26).
---
--- @param recipient table session
--- @param senderAgencyId string
--- @param hasPermission function(session, permission) -> boolean
--- @return boolean
function Chat.canReceive(recipient, senderAgencyId, hasPermission)
    if not hasPermission(recipient, 'comms.pdchat.view') then return false end
    if recipient.agencyId == senderAgencyId then return true end

    return hasPermission(recipient, 'comms.pdchat.all')
end

FredPD.Modules.chat = Chat
