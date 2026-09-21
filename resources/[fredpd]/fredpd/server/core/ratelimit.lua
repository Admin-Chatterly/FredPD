--- Per-session rate limiting (spec 3.5).
---
--- A fixed window per route per session. Not because bursts are precious, but
--- because every route is reachable from a client, and a client can call one in
--- a loop -- the police chat and any search especially.
---
--- Pure logic: the clock is injected, so busted can test expiry without waiting.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local RateLimit = {}

--- src -> route name -> { count, windowStart }
local buckets = {}

--- Records a call and says whether it is allowed.
---
--- @param src number server id
--- @param routeName string
--- @param limit table { per = number, window = seconds }
--- @param now number|nil injected clock, for tests
--- @return boolean allowed
--- @return number|nil retryAfter seconds until the window resets
function RateLimit.take(src, routeName, limit, now)
    now = now or os.time()

    local forSession = buckets[src]
    if not forSession then
        forSession = {}
        buckets[src] = forSession
    end

    local bucket = forSession[routeName]

    if not bucket or now - bucket.windowStart >= limit.window then
        forSession[routeName] = { count = 1, windowStart = now }
        return true, nil
    end

    if bucket.count >= limit.per then
        return false, limit.window - (now - bucket.windowStart)
    end

    bucket.count = bucket.count + 1
    return true, nil
end

--- Forgets a disconnected player, so the table does not grow without bound.
function RateLimit.drop(src)
    buckets[src] = nil
end

AddEventHandler('playerDropped', function()
    RateLimit.drop(source)
end)

FredPD.Core.ratelimit = RateLimit
