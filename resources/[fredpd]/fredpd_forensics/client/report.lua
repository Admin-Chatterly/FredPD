--- The one way an observation leaves this client (spec 8.3.1, 8.11, ADR-011).
---
--- Every sensor in this resource funnels through `Report.observe`, and there is
--- deliberately no `TriggerServerEvent` anywhere in `fredpd_forensics`. The
--- core's `forensics.observe` route is the gateway (invariant 3), reached the
--- only way a satellite may reach one: ox_lib callbacks use global event names,
--- so the callback the core registered as `fredpd:forensics.observe` answers a
--- call made from here. This resource registers nothing of its own.
---
--- What goes up is the smallest thing that can be sent -- which moment
--- happened, and at most a network id and a door index. Never a position, never
--- a weapon, never an identifier, never a type of evidence, never a claim that
--- evidence should exist. The server looks all of that up from its own state
--- (8.3.2) and answers with an empty table either way, so nothing that comes
--- back down says whether anything was created (8.11).
---
--- Three things live here rather than in each sensor:
---
---   * **Budgets.** The route rate-limits per player and per kind and refuses
---     past the ceiling (8.3.2). A client that keeps calling into a refusal
---     spends network on nothing, so the same ceilings are mirrored here,
---     slightly tighter, and the call is simply not made. Automatic fire is the
---     case that matters: ten shots a second would empty a thirty-second budget
---     in fifteen seconds and then keep sending.
---   * **Backoff.** A refusal that will still be a refusal in a second -- no
---     session, no permission -- mutes every sensor for minutes. Most players
---     on a server are not officers, and a criminal's client must not retry a
---     route it cannot pass once per shot, all night.
---   * **Cost.** The call is the non-blocking form of `lib.callback`, so a
---     sensor never yields and this file never starts a thread. Nothing here
---     runs unless a sensor fired, which is what keeps the resource at 0.00 ms
---     while nothing is happening (spec 12.1).

FredPDForensics = FredPDForensics or {}
FredPDForensics.Client = FredPDForensics.Client or {}

local Report = {}

--- The core's route, by the global event name ox_lib gives it.
local ROUTE <const> = 'fredpd:forensics.observe'

--- Client-side ceilings, per observation kind.
---
--- `per` and `window` mirror the route's own per-kind limits; they are set a
--- little under the server's so the sensor stops before the server has to, and
--- a player who is refused here is never refused there. `minGap` is the part
--- the server has no equivalent for: it collapses a burst that arrives faster
--- than any of it could mean anything -- two doors of the same car in the same
--- frame, or a shotgun's pellets arriving as separate events.
---
--- Kinds not listed are not reportable from this client. `blood`, `bullet` and
--- every other trace the server builds from its own events are absent on
--- purpose; see the damage section in `sensors.lua`.
local BUDGETS <const> = {
    -- The server samples casings from shots (8.2), so what is sent is every
    -- shot the client saw, up to a rate a human trigger finger cannot exceed
    -- for long. Sustained automatic fire is cut off here, and the casings from
    -- it were being sampled away anyway.
    shot = { per = 120, window = 30000, minGap = 120 },
    reload = { per = 15, window = 30000, minGap = 750 },
    vehicle_door = { per = 24, window = 30000, minGap = 250 },
    surface = { per = 24, window = 30000, minGap = 400 },
}

--- How long a refusal silences every sensor, by the code that came back.
---
--- `no_session` and `forbidden` are the ordinary answer for a player who is not
--- an officer, so they are measured in minutes: the sensor goes quiet and tries
--- again occasionally, rather than asking once per shot forever. `internal` is
--- held the same way, because a route that is throwing is not a route that gets
--- better by being called again.
local MUTE <const> = {
    no_session = 300000,
    forbidden = 300000,
    rate_limited = 30000,
    invalid = 300000,
    internal = 60000,
    stale_permissions = 60000,
}

--- kind -> { count, windowStart, last }, in game-timer milliseconds.
local buckets = {}

--- Game time before which nothing at all is sent.
local mutedUntil = 0

--- Spends one unit of a kind's budget, or refuses.
---
--- @return boolean
local function afford(kind, now)
    local budget = BUDGETS[kind]
    if not budget then return false end

    local bucket = buckets[kind]

    if not bucket then
        buckets[kind] = { count = 1, windowStart = now, last = now }
        return true
    end

    if now - bucket.last < budget.minGap then return false end

    if now - bucket.windowStart >= budget.window then
        bucket.count = 1
        bucket.windowStart = now
        bucket.last = now
        return true
    end

    if bucket.count >= budget.per then return false end

    bucket.count = bucket.count + 1
    bucket.last = now

    return true
end

--- What the route answered.
---
--- The body of a successful answer is empty and is not read: whether a casing
--- was left, whether the print was a glove mark, whether anything exists at all
--- is not the client's to know (8.11). Only the refusal code is used, and only
--- to decide how long to stay quiet.
local function answered(response)
    if type(response) ~= 'table' or response.ok then return end

    local hold = MUTE[response.err]
    if not hold then return end

    mutedUntil = GetGameTimer() + hold
end

--- Reports that a moment happened.
---
--- @param kind string a key of `BUDGETS`
--- @param context table|nil { netId = number|nil, doorIndex = number|nil }
--- @return boolean sent -- whether the call was made, which says nothing about
---   what the server did with it
function Report.observe(kind, context)
    local now = GetGameTimer()

    if now < mutedUntil then return false end
    if not afford(kind, now) then return false end

    -- Built field by field rather than passed through, so a sensor cannot widen
    -- the payload by accident: whatever else a caller put in `context` stays on
    -- this client.
    local payload = { kind = kind }

    if context then
        payload.netId = context.netId
        payload.doorIndex = context.doorIndex
    end

    lib.callback(ROUTE, false, answered, payload)

    return true
end

FredPDForensics.Client.report = Report
