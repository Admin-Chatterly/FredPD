--- Evidence logic (spec 8).
---
--- No natives and no database, so busted can test it. The rules worth testing
--- are the ones that decide what a client is told and what a lab concludes,
--- and neither should need a running game to verify.
---
--- Section 8's preamble is explicit that the reference script's mechanics are
--- the model and its code is not reused. The difference that matters is here:
--- a result is computed on the server from truth the client never received.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Evidence = {}

-- -----------------------------------------------------------------------------
-- What a client may see (8.11)
-- -----------------------------------------------------------------------------

--- Fields safe to send to a session holding `evidence.item.view`.
---
--- An allowlist, not a denylist. A column added to `fpd_evidence` later is
--- invisible until somebody names it here, which is the right default: the
--- failure mode of a denylist is silent disclosure.
local PUBLIC_FIELDS <const> = {
    'id', 'ref', 'evidenceNumber', 'type', 'packaging', 'sealState',
    'markerNumber', 'description', 'caseNumber', 'sceneId',
    'collectedAt', 'storageLocation', 'status',
}

--- Strips an evidence row down to what may leave the server.
---
--- Note what is absent: `quality`, the owner, the weapon serial. Quality is
--- excluded deliberately -- it is an input to the lab, and showing it to the
--- collecting officer would tell them how likely a match is before the lab has
--- looked, which is the metagame 8.11 exists to prevent.
--- @param row table
--- @return table
function Evidence.public(row)
    local out = {}

    for index = 1, #PUBLIC_FIELDS do
        local field = PUBLIC_FIELDS[index]
        if row[field] ~= nil then out[field] = row[field] end
    end

    return out
end

--- Render data for a piece of uncollected evidence lying in the world (8.1.6).
---
--- Everything a client needs to draw it and nothing else. No owner, no id that
--- could be used to ask about it, no quality.
function Evidence.renderData(item)
    return {
        key = item.key,
        type = item.type,
        x = item.x,
        y = item.y,
        z = item.z,
        -- Latent evidence is invisible until processed (8.4). The client is
        -- told whether it has been revealed, never that it is there while it is
        -- still latent -- the server does not send it at all until then.
        model = item.model,
    }
end

-- -----------------------------------------------------------------------------
-- Numbering (invariant 1: generated server-side, never accepted from input)
-- -----------------------------------------------------------------------------

--- `LSPD-2026-000123`. Sortable, unambiguous when read aloud on the radio, and
--- unique per agency and year.
function Evidence.evidenceNumber(agencyShort, year, sequence)
    return ('%s-%04d-%06d'):format(tostring(agencyShort):upper(), year, sequence)
end

--- `LSPD-S-2026-0042` for a scene.
function Evidence.sceneNumber(agencyShort, year, sequence)
    return ('%s-S-%04d-%04d'):format(tostring(agencyShort):upper(), year, sequence)
end

-- -----------------------------------------------------------------------------
-- Degradation (8.1.4)
-- -----------------------------------------------------------------------------

--- How much of a trace is left after time, weather and handling.
---
--- Rain only touches evidence that is outdoors; a print on a steering wheel
--- does not wash away. Cleaning drops the yield sharply but never to zero,
--- because luminol still finds cleaned blood (8.10) -- a cleaned scene is a
--- worse scene, not an innocent one.
---
--- @param baseQuality number 0-100 at the moment it was created
--- @param ageSeconds number
--- @param context table { decayPerHour, outdoors, raining, cleaned, contaminated }
--- @return number 0-100
function Evidence.qualityAfter(baseQuality, ageSeconds, context)
    context = context or {}

    local quality = baseQuality
    local hours = math.max(ageSeconds, 0) / 3600

    quality = quality - (context.decayPerHour or 2) * hours

    if context.outdoors and context.raining then
        quality = quality - 25
    end

    if context.cleaned then
        quality = quality * 0.25
    end

    -- Someone walked through the scene without protective equipment (8.4).
    if context.contaminated then
        quality = quality * 0.6
    end

    if quality < 0 then return 0 end
    if quality > 100 then return 100 end

    return math.floor(quality + 0.5)
end

-- -----------------------------------------------------------------------------
-- Merging (8.3.5)
-- -----------------------------------------------------------------------------

--- Should two traces be treated as one?
---
--- Same type, same owner, close together. Without this, emptying a magazine
--- into a wall leaves thirty separate blood rows and the grid cell becomes a
--- performance problem rather than an investigation (spec 12).
---
--- Compares squared distance to avoid a square root in the generation hot path.
function Evidence.shouldMerge(left, right, radius)
    if left.type ~= right.type then return false end
    if left.ownerKey ~= right.ownerKey then return false end

    local dx, dy, dz = left.x - right.x, left.y - right.y, left.z - right.z
    local limit = radius or 0.5

    return (dx * dx + dy * dy + dz * dz) <= (limit * limit)
end

-- -----------------------------------------------------------------------------
-- Lab results (8.7)
-- -----------------------------------------------------------------------------

--- Turnaround in seconds, from the analysis type and priority.
---
--- Real minutes, configurable, and persisted as a due time rather than counted
--- down in memory so a restart does not reset the queue.
function Evidence.turnaroundSeconds(analysis, priority, config)
    config = config or {}

    local minutes = (config.analysisMinutes or {})[analysis] or 30
    local multiplier = ({ routine = 1.0, expedited = 0.5, urgent = 0.25 })[priority] or 1.0

    return math.floor(minutes * multiplier * 60)
end

--- The DNA result for a sample of a given quality.
---
--- The thresholds are the whole mechanic: a degraded sample gives a partial
--- profile, which is a lead and not an identification. Two contributors is a
--- mixture however good the sample -- that is what a mixture means.
function Evidence.dnaResult(quality, contributors)
    contributors = contributors or 1

    if quality < 15 then return 'no_profile' end
    if contributors > 1 then return 'mixture' end
    if quality < 50 then return 'partial_profile' end

    return 'profile_obtained'
end

--- The result of comparing a sample against a named reference.
---
--- `matches` comes from comparing the hidden values on the server. A client has
--- never seen either of them, so this cannot be pre-computed anywhere else.
function Evidence.comparisonResult(matches, quality)
    if quality < 15 then return 'insufficient' end

    if matches then
        -- A poor sample that matches is still not court-grade. It is a reason
        -- to go and take a fresh reference (8.1.3).
        return quality < 50 and 'inconclusive' or 'identification'
    end

    return quality < 50 and 'inconclusive' or 'exclusion'
end

--- The result of searching an index (8.8).
---
--- Never 'identification'. A database hit is a candidate and needs confirming
--- against a fresh reference sample; returning an identification here is the
--- shortcut that turns an investigation into a lookup.
function Evidence.searchResult(hitCount, quality)
    if quality < 15 then return 'insufficient' end
    if hitCount and hitCount > 0 then return 'candidate_match' end

    return 'no_match'
end

--- Is this result one a court may hear as an identification?
---
--- Used to decide whether a lead may be promoted. Kept as a function rather
--- than a comparison at each call site so the rule is in one place.
function Evidence.isCourtGrade(resultCode)
    return resultCode == 'identification' or resultCode == 'exclusion'
end

FredPD.Modules.evidence = Evidence
