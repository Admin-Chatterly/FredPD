--- Asking a player to show their ID, and hearing their answer (spec 7.2.1).
---
--- The question goes to one player as a net event carrying a one-time token;
--- the answer comes back through a route (`field.person.consent`, a
--- `route.public` in routes.lua) that must name that token and arrive from
--- that player. Nothing else can answer for them: not another client, not a
--- flood of guesses at a callback key (invariant 3).
---
--- One question per player at a time, and after a refusal or silence nobody
--- may ask them again for a minute -- the prompt takes the screen, and an
--- officer must not be able to hold a suspect frozen by asking over and over.

FredPD = FredPD or {}
FredPD.Field = FredPD.Field or {}

local Consent = {}

--- How long the player has to answer, and how long a "no" stands.
Consent.ANSWER_SECONDS = 20
Consent.COOLDOWN_SECONDS = 60

--- targetId -> { token, answer (promise) }
local pending = {}

--- targetId -> os.time() before which nobody may ask again
local cooldown = {}

local function token()
    local parts = {}
    for index = 1, 4 do parts[index] = ('%08x'):format(math.random(0, 0x7fffffff)) end
    return table.concat(parts)
end

--- Asks and waits. `false` for a refusal, silence, a player already being
--- asked, or one who said no within the last minute.
--- @param targetId number
--- @param callsign string|nil shown to the player so they know who asks
--- @return boolean shown
function Consent.ask(targetId, callsign)
    if pending[targetId] then return false end
    if (cooldown[targetId] or 0) > os.time() then return false end

    local request = { token = token(), answer = promise.new(), settled = false }
    pending[targetId] = request

    local function settle(shown)
        if request.settled then return end
        request.settled = true
        if pending[targetId] == request then pending[targetId] = nil end
        if not shown then cooldown[targetId] = os.time() + Consent.COOLDOWN_SECONDS end
        request.answer:resolve(shown)
    end

    request.settle = settle

    TriggerClientEvent('fredpd:showIdRequest', targetId, { callsign = callsign, token = request.token })
    SetTimeout(Consent.ANSWER_SECONDS * 1000, function() settle(false) end)

    return Citizen.Await(request.answer)
end

--- The player's own answer. Ignored unless it comes from the player who was
--- asked and names the token they were sent.
--- @return boolean accepted
function Consent.answer(src, answerToken, shown)
    local request = pending[src]
    if not request or request.token ~= answerToken then return false end

    request.settle(shown == true)
    return true
end

AddEventHandler('playerDropped', function()
    local request = pending[source]
    if request then request.settle(false) end
    cooldown[source] = nil
end)

FredPD.Field.consent = Consent
