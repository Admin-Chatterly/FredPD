--- Frihetsberövande: gripande, anhållande, häktning (spec 7.9).
---
--- Pure: no natives, no database, no locale lookups, so busted exercises it
--- outside FXServer (`spec/frihet_spec.lua`).
---
--- **The clocks are the module.** Everything else here is a state machine of the
--- kind the anmälan module already has; what makes this one worth its own file
--- is that two of its transitions have statutory deadlines, and both are
--- specified in a way that is easy to implement almost correctly:
---
---   * **RB 24:12** -- a häktningsframställan must reach the court *senast
---     klockan tolv tredje dagen efter anhållningsbeslutet*. Not seventy-two
---     hours. A wall-clock noon, three days after the decision, which lands a
---     different number of hours away depending on what time of day the
---     anhållande happened -- anything from 60 to 84.
---   * **RB 24:13** -- the häktningsförhandling must be held at the latest four
---     **dygn** after the gripande. That one really is 96 hours.
---
--- An implementation that treated the first as 72 hours would be wrong in one
--- direction for every afternoon anhållande and wrong in the other for every
--- morning one, and would be wrong quietly: the countdown on the screen would
--- simply show the wrong number, and nobody would find out until a detention
--- was challenged.
---
--- Times are epoch seconds throughout, and the timezone offset is passed in
--- rather than read: the noon in RB 24:12 is a *local* noon (spec 5.2 stores
--- UTC), and a function that read the convar itself could not be tested against
--- a server in a different timezone.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Frihet = {}

Frihet.HOUR = 3600
Frihet.DAY = 86400

--- RB 24:13. Four dygn from the gripande to the häktningsförhandling.
Frihet.FORHANDLING_HOURS = 96

--- RB 24:12. Noon on the third day after the anhållandebeslut.
Frihet.FRAMSTALLAN_DAYS = 3
Frihet.FRAMSTALLAN_HOUR = 12

-- -----------------------------------------------------------------------------
-- Statuses
-- -----------------------------------------------------------------------------

--- The stages of a frihetsberövande, in the order they happen.
local STATUSES <const> = { 'gripen', 'anhallen', 'framstalld', 'haktad', 'frigiven' }

local IS_STATUS <const> = {}
for index = 1, #STATUSES do IS_STATUS[STATUSES[index]] = true end

function Frihet.isStatus(value) return IS_STATUS[value] == true end

function Frihet.statuses()
    local out = {}
    for index = 1, #STATUSES do out[index] = STATUSES[index] end
    return out
end

--- Which transitions exist, by the action that makes them.
---
--- Read as: from this status, this action lands on that status.
---
--- **`frigiv` is available from every open stage**, which is the point of
--- listing it against all four rather than treating release as an ending that
--- only follows häktning. Somebody who is gripen and not anhållen within the
--- time the prosecutor has must be released; somebody the court refuses to
--- häkta is released from `framstalld`. A release path that only existed at the
--- end would leave the commonest outcome unrecordable.
---
--- There is no transition *out* of `frigiven`. A person released and later
--- arrested again is a new chain, with its own gripande, its own number and its
--- own clocks -- not a reopening of the old one, which would restart a
--- statutory deadline that had already expired.
local TRANSITIONS <const> = {
    anhall    = { gripen = 'anhallen' },
    framstall = { anhallen = 'framstalld' },
    hakta     = { framstalld = 'haktad' },
    frigiv    = {
        gripen = 'frigiven', anhallen = 'frigiven',
        framstalld = 'frigiven', haktad = 'frigiven',
    },
}

--- Who may take each decision, as the capacity the FU is led in (RB).
---
--- `polis` is an ordinary officer; `aklagare` is the prosecutor; `domare` is the
--- court. These are the three decision-makers of 7.9, and the whole reason the
--- chain has three stages rather than one.
local DECIDER <const> = {
    anhall = 'aklagare',
    framstall = 'aklagare',
    hakta = 'domare',
    -- Release is the exception: any of the three may release, and so may the
    -- officer holding the person, because a frihetsberövande that should end
    -- must be able to end immediately. Nothing about letting somebody go needs
    -- to wait for the right rank to be online.
    frigiv = nil,
}

--- The status an action lands on, or nil when it is not available here.
function Frihet.nextStatus(status, action)
    local row = TRANSITIONS[action]
    if not row then return nil end

    return row[status]
end

--- The capacity an action requires, or nil when any may take it.
function Frihet.deciderFor(action)
    return DECIDER[action]
end

--- Is this person still being held?
function Frihet.isOpen(row)
    return type(row) == 'table' and row.status ~= 'frigiven'
end

--- Is this a locale key the custody log may carry?
---
--- `FrihetLog.kind` is a *key* and not an enum on purpose: what a department
--- logs is a matter of its own standing orders rather than of what the law
--- names, and an enum would need a migration before a server could record
--- something its own routines require.
---
--- What that argument does not license is a free string. The NUI renders the
--- kind with `t()`, and `t()` falls back to printing an unknown key verbatim --
--- so a 64-character field with no shape let an officer write an arbitrary
--- sentence into a custody record and have it drawn as a label, in English, in
--- both locales. That is invariant 6 gone round the back.
---
--- The prefix is the whole check, and it keeps the freedom the comment wanted:
--- a department adds `frihet.logKind.visitation` to its locale overlay and the
--- server accepts it without a schema change. What it cannot do is send prose.
local LOG_KIND_PATTERN <const> = '^frihet%.logKind%.[a-z][a-z0-9_]*$'

function Frihet.isLogKind(value)
    return type(value) == 'string' and value:match(LOG_KIND_PATTERN) ~= nil
end

--- Is this a kind an officer may write by hand?
---
--- The stand-in kinds (`frihet.logKind.stand_in_*`) are written by the server
--- when a stand-in decision is taken (7.9.1), and only then. An entry of that
--- kind added through the log would read, to the åklagare reviewing the chain
--- in the morning, as a decision nobody took.
local RESERVED_LOG_PREFIX <const> = 'frihet.logKind.stand_in_'

function Frihet.isOfficerLogKind(value)
    return Frihet.isLogKind(value)
        and value:sub(1, #RESERVED_LOG_PREFIX) ~= RESERVED_LOG_PREFIX
end

-- -----------------------------------------------------------------------------
-- The clocks
-- -----------------------------------------------------------------------------

--- The offset a configured setting asks for, in seconds east of UTC.
---
--- `nil` means "use the host's own zone", which is what a correctly configured
--- deployment wants: the host's C library carries a tz database and resolves
--- daylight saving, and Lua has no way to do that from an IANA name.
---
--- The setting exists for the host that cannot be reconfigured. A server whose
--- machine runs in UTC while the department it simulates is in Sweden computes
--- RB 24:12's noon at 12:00 UTC — an hour or two early, on the deadline an
--- officer quotes to a prosecutor — and `fredpd:timezone_offset` is how that
--- is corrected without touching the host clock.
---
--- A fixed offset cannot follow daylight saving, and that is the reason it is
--- the fallback rather than the default: `+01:00` is right in Stockholm in
--- January and an hour out in July. A host set to `Europe/Stockholm` needs
--- nothing here.
---
--- Accepts `+HH:MM`, `-HH:MM`, `HH:MM` and a plain number of minutes. Anything
--- else is `nil`, with the second return saying it was rejected, because a
--- typo in a convar must not silently become a different deadline.
---
--- Two bounds, and both reject rather than round:
---
---   * **At most fourteen hours.** The furthest any zone reaches is +14:00.
---   * **A whole quarter of an hour.** Every timezone on earth is a multiple
---     of fifteen minutes from UTC — :00, :15, :30 and :45, the last two being
---     India and Nepal. This is the bound that catches the likely typo:
---     `+1`, meant as an hour, reads as one minute otherwise, and one minute
---     is not a timezone anybody lives in.
---
--- @param value string|nil
--- @return number|nil seconds east of UTC
--- @return boolean true when a value was given and could not be read
function Frihet.offsetFromSetting(value)
    if value == nil or value == '' then return nil, false end
    if type(value) ~= 'string' then return nil, true end

    local text = value:gsub('%s', '')

    local minutes

    local sign, hourPart, minutePart = text:match('^([+-]?)(%d%d?):(%d%d)$')

    if hourPart then
        minutes = (tonumber(hourPart) * 60) + tonumber(minutePart)
        if sign == '-' then minutes = -minutes end
    else
        -- Minutes, not seconds: `-330` for India is easier to get right, and
        -- to spot wrong, than `-19800`.
        local plain = tonumber(text)

        if not plain or plain ~= math.floor(plain) then return nil, true end

        minutes = plain
    end

    if math.abs(minutes) > 14 * 60 then return nil, true end
    if minutes % 15 ~= 0 then return nil, true end

    return minutes * 60, false
end

--- Noon, local time, `days` days after the day `at` falls on.
---
--- The arithmetic is done on a broken-down *local* date rather than by adding
--- seconds, which is what makes it correct across a daylight-saving boundary:
--- three days after a Friday afternoon in March is not 72 hours later in
--- Sweden, and `os.time` on a table with `isdst = false` lets the C library
--- resolve that instead of this function pretending to.
---
--- @param at number epoch seconds of the anhållandebeslut
--- @param days number
--- @param hour number
--- @param offset number|nil seconds east of UTC; nil means the server's own zone
--- @return number epoch seconds
function Frihet.localNoonAfter(at, days, hour, offset)
    -- With an explicit offset the calculation is done in that zone: shift into
    -- it, take the calendar date there, and shift back. Without one, the
    -- server's own zone is used through `os.date('*t')`, which is what a
    -- single-timezone deployment wants and what `fredpd:timezone` configures.
    local shifted = offset and (at + offset) or at
    local parts = offset and os.date('!*t', shifted) or os.date('*t', shifted)

    parts.day = parts.day + days
    parts.hour = hour
    parts.min = 0
    parts.sec = 0
    parts.isdst = nil

    -- `os.time` normalises an out-of-range day (the 34th of March becomes the
    -- 3rd of April), so adding to `day` needs no month arithmetic here.
    local result = offset
        and (Frihet.timegm(parts) - offset)
        or os.time(parts)

    return result
end

--- `os.time` for a UTC date, which Lua's standard library does not provide.
---
--- Only reached on the explicit-offset path above, where the broken-down table
--- is already in the target zone and must not be re-interpreted as local. The
--- usual trick -- `os.time` then correct by the difference between `os.date`
--- and `os.date('!')` -- is used rather than reimplementing the calendar,
--- because the calendar is exactly the part worth not reimplementing.
function Frihet.timegm(parts)
    local copy = {
        year = parts.year, month = parts.month, day = parts.day,
        hour = parts.hour, min = parts.min, sec = parts.sec, isdst = false,
    }

    local asLocal = os.time(copy)
    if not asLocal then return nil end

    -- How far the server's own zone is from UTC at that instant.
    local utcParts = os.date('!*t', asLocal)
    utcParts.isdst = false

    return asLocal + (asLocal - os.time(utcParts))
end

--- The two statutory deadlines for a chain, and whether each has passed.
---
--- Returns nil for a deadline whose starting moment has not happened yet: there
--- is no häktningsframställan deadline before there is an anhållande, and a
--- screen showing one would be counting down to nothing.
---
--- @param row table the frihetsberövande
--- @param now number epoch seconds
--- @param offset number|nil timezone offset for the RB 24:12 noon
--- @return table { framstallan = { at, remaining, passed }|nil, forhandling = …|nil }
function Frihet.deadlines(row, now, offset)
    local out = {}

    if type(row) ~= 'table' then return out end

    -- A released chain has no deadlines. Neither statutory clock is about the
    -- passage of time on its own: RB 24:12 bounds how long somebody may be held
    -- before the court is asked, and RB 24:13 bounds how long before it hears
    -- them. Once they are out, both questions are answered.
    --
    -- Without this the history list drew "Överskriden med 4 d 8 h" and the red
    -- attention banner against somebody released days ago -- a breach warning
    -- for a detention that ended, on the screen whose whole job is to be
    -- believed about breaches.
    if not Frihet.isOpen(row) then return out end

    -- RB 24:12, from the anhållande. Only while it is still the live question:
    -- once the framställan has been made the deadline has been met and a
    -- countdown against it is noise.
    if row.anhallenAt and not row.framstallanAt then
        local at = Frihet.localNoonAfter(
            row.anhallenAt, Frihet.FRAMSTALLAN_DAYS, Frihet.FRAMSTALLAN_HOUR, offset)

        out.framstallan = { at = at, remaining = at - now, passed = now > at }
    end

    -- RB 24:13, four dygn from the gripande -- or from the anhållande where
    -- there was no gripande, which is the case where somebody anhållen i sin
    -- frånvaro presents themselves rather than being arrested.
    local start = row.gripenAt or row.anhallenAt

    if start and not row.haktadAt then
        local at = start + Frihet.FORHANDLING_HOURS * Frihet.HOUR

        out.forhandling = { at = at, remaining = at - now, passed = now > at }
    end

    return out
end

--- How long this person has been held, in seconds.
---
--- Measured to the release where there is one, and to `now` while it is still
--- running -- so a closed chain reports what it was rather than growing forever.
function Frihet.heldFor(row, now)
    if type(row) ~= 'table' then return nil end

    local start = row.gripenAt or row.anhallenAt
    if not start then return nil end

    return (row.frigivenAt or now) - start
end

--- The deadline that matters most right now, for the countdown on the screen.
---
--- The nearer of the two, and a passed one always wins over a pending one: a
--- missed deadline is not something to show second.
---
--- @return string|nil which ('framstallan' or 'forhandling')
--- @return table|nil the deadline
function Frihet.nextDeadline(row, now, offset)
    local deadlines = Frihet.deadlines(row, now, offset)

    local best, bestKey

    for _, key in ipairs({ 'framstallan', 'forhandling' }) do
        local candidate = deadlines[key]

        if candidate then
            local better

            if not best then
                better = true
            elseif candidate.passed ~= best.passed then
                better = candidate.passed
            else
                better = candidate.at < best.at
            end

            if better then best, bestKey = candidate, key end
        end
    end

    return bestKey, best
end

-- -----------------------------------------------------------------------------
-- Who may do what
-- -----------------------------------------------------------------------------

--- May this session take this decision?
---
--- Two questions, and they are separate:
---
---   1. Is the transition available from where the chain is? A häktning before
---      an anhållande is not a permissions problem, it is a detention with no
---      legal basis.
---   2. Does the session hold the capacity the decision requires? An officer
---      cannot anhålla -- that is the prosecutor's decision (RB 24:6), and it
---      is the separation the three stages exist to record.
---
--- `capacity` is resolved by the route from the session's permissions, so this
--- file holds no session logic.
---
--- @param row table
--- @param action string
--- @param capacity string|nil 'polis', 'aklagare' or 'domare'
--- @return boolean
--- @return string|nil why not
function Frihet.canDecide(row, action, capacity)
    if type(row) ~= 'table' then return false, 'not_found' end

    if not Frihet.isOpen(row) then return false, 'already_released' end

    -- `out_of_order` rather than `not_allowed`, which is the validator's word
    -- for "not one of this field's permitted values". They are different
    -- objections and an officer reads the difference: a häktning before an
    -- anhållande is a detention with no legal basis, not a typo in a dropdown,
    -- and "Status -- not an allowed value" is the screen failing to say so.
    if not Frihet.nextStatus(row.status, action) then return false, 'out_of_order' end

    local required = Frihet.deciderFor(action)
    if required and capacity ~= required then return false, 'wrong_capacity' end

    return true
end

--- Does this chain need attention now?
---
--- Used for the list a supervisor watches. True when either statutory deadline
--- has passed, or when one is inside the warning window -- deliberately
--- generous, because the cost of a warning that was not needed is a row
--- highlighted on a screen, and the cost of missing one is an unlawful
--- detention.
Frihet.WARN_SECONDS = 6 * 3600

function Frihet.needsAttention(row, now, offset)
    local _, deadline = Frihet.nextDeadline(row, now, offset)
    if not deadline then return false end

    return deadline.passed or deadline.remaining <= Frihet.WARN_SECONDS
end

--- The statutory deadlines that fall inside the next `window` seconds and
--- have not passed yet, for the warning pushed to the officers who have to
--- act on them (spec 7.9). Sorted so the output is stable.
---
--- @return table list of deadline keys ('framstallan', 'forhandling')
function Frihet.deadlinesDueWithin(row, now, offset, window)
    local out = {}
    local deadlines = Frihet.deadlines(row, now, offset)

    for _, key in ipairs({ 'framstallan', 'forhandling' }) do
        local deadline = deadlines[key]

        if deadline and not deadline.passed and deadline.remaining <= window then
            out[#out + 1] = key
        end
    end

    return out
end

--- Who decides next in the chain from a status, as the permission that
--- decision needs: the åklagare after a gripande and after the anhållande
--- (framställan), the domare after a framställan. Nil when nothing waits on a
--- decision-maker.
local NEXT_DECISION <const> = {
    gripen = 'frihet.anhallande',
    anhallen = 'frihet.anhallande',
    framstalld = 'frihet.haktning',
}

function Frihet.nextDecisionPermission(status)
    return NEXT_DECISION[status]
end

-- -----------------------------------------------------------------------------
-- Standing in (spec 7.9.1)
-- -----------------------------------------------------------------------------

--- The permission that lets somebody stand in for each capacity when nobody
--- holding it is signed on.
---
--- The roles stay real. An åklagare decides an anhållande when one is on; the
--- stand-in exists for the night nobody plays the prosecutor, when the chain
--- would otherwise sit at `gripen` until the person had to be released for want
--- of anyone to decide. A stand-in decision is marked as one in the custody log
--- and the audit trail, so it can be reviewed by the real role afterwards.
local FALLBACK_PERMISSION <const> = {
    aklagare = 'frihet.fallback.aklagare',
    domare = 'frihet.fallback.domare',
}

--- Which earlier stamps on the chain disqualify a stand-in for each action.
---
--- The separation RB builds in does not go away because the decision-maker is
--- a stand-in: the officer who made the arrest does not also decide whether it
--- holds, and whoever anhöll or sent the framställan does not then sit as the
--- court on it. A real åklagare or domare is somebody else by construction; a
--- supervisor standing in is not, so it is checked here.
local CONFLICTS <const> = {
    anhall = { 'gripenBy' },
    framstall = { 'gripenBy' },
    hakta = { 'gripenBy', 'anhallenBy', 'framstallanBy' },
}

--- Did this person take an earlier step on the chain that bars them from
--- taking this decision as the court? Checked on the ordinary häktning too:
--- somebody holding both a domare's grant and a stand-in åklagare's grant
--- could otherwise anhålla as the stand-in and then häkta as themselves.
local COURT_CONFLICTS <const> = { hakta = { 'anhallenBy', 'framstallanBy' } }

function Frihet.actedOn(row, action, discordId)
    for _, field in ipairs(COURT_CONFLICTS[action] or {}) do
        if row[field] ~= nil and row[field] == discordId then return true end
    end

    return false
end

function Frihet.fallbackPermission(capacity)
    return FALLBACK_PERMISSION[capacity]
end

--- The capacity a session may stand in with for this action, or nil and why.
---
--- @param row table the chain, with its `*By` stamps
--- @param action string anhall | framstall | hakta
--- @param capacity string the session's own capacity (`capacityOf`)
--- @param holds fun(permission: string): boolean the session's grants
--- @param deciderOnline boolean somebody holding the real capacity is on
--- @param discordId string the session's own Discord id
--- @return string|nil capacity to decide in
--- @return string|nil reason: not_needed, wrong_capacity, a `canDecide`
---   refusal, decider_online or own_chain
function Frihet.fallbackCapacity(row, action, capacity, holds, deciderOnline, discordId)
    local required = Frihet.deciderFor(action)

    -- Release needs nobody; a session that already holds the capacity uses the
    -- ordinary route, where its decision is not a stand-in's.
    if not required or capacity == required then return nil, 'not_needed' end

    local permission = FALLBACK_PERMISSION[required]
    if not permission or not holds(permission) then return nil, 'wrong_capacity' end

    -- The court does not stand in for the prosecutor. A domare who could also
    -- anhålla would be deciding, a day later, on their own anhållande.
    if required == 'aklagare' and capacity == 'domare' then return nil, 'wrong_capacity' end

    local ok, why = Frihet.canDecide(row, action, required)
    if not ok then return nil, why end

    if deciderOnline then return nil, 'decider_online' end

    for _, field in ipairs(CONFLICTS[action] or {}) do
        if row[field] ~= nil and row[field] == discordId then return nil, 'own_chain' end
    end

    return required
end

FredPD.Modules.frihet = Frihet

return Frihet
