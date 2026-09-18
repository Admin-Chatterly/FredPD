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

--- Fields of a lab analysis that may leave the server before its result is out.
---
--- The queue is readable long before a conclusion exists: an analyst needs to
--- see what is waiting, who has it and when it is due. None of that says what
--- the answer is.
local ANALYSIS_FIELDS <const> = {
    'id', 'requestId', 'evidenceId', 'evidenceNumber', 'analysis', 'status',
    'assignedTo', 'startedAt', 'dueAt', 'completedAt', 'priority', 'caseNumber',
}

--- Strips a lab analysis row down to what this reader may see (8.11).
---
--- The result is the whole value of the record and it is withheld twice over:
--- until the analysis is actually finished, and then only from readers cleared
--- to see lab conclusions. An officer who may look at an evidence item is not
--- thereby cleared to read what the lab found on it.
---
--- @param row table
--- @param canSeeResult boolean the reader holds a lab permission
--- @return table
function Evidence.analysisPublic(row, canSeeResult)
    local out = {}

    for index = 1, #ANALYSIS_FIELDS do
        local field = ANALYSIS_FIELDS[index]
        if row[field] ~= nil then out[field] = row[field] end
    end

    local finished = row.status == 'complete' or row.status == 'reviewed' or row.status == 'released'

    if canSeeResult and finished then
        out.resultCode = row.resultCode
        out.observations = row.observations
    end

    return out
end

--- Turns a list of id strings into integers (spec 3.5).
---
--- The input validator has no integer-list type, so a request naming several
--- items sends them as strings and they are checked here instead of being
--- trusted. Anything that is not a whole positive number fails the whole list:
--- a lab request that silently analysed four of the five items an officer
--- selected would be worse than one that was refused.
---
--- @param list table list of strings
--- @param max number|nil
--- @return table|nil ids
--- @return string|nil reason
function Evidence.parseIds(list, max)
    if type(list) ~= 'table' then return nil, 'type' end
    if #list == 0 then return nil, 'required' end
    if max and #list > max then return nil, 'too_many' end

    local ids, seen = {}, {}

    for index = 1, #list do
        local id = tonumber(list[index])

        if not id or id ~= math.floor(id) or id < 1 then
            return nil, 'not_integer'
        end

        -- The same item twice would queue the same analysis twice and bill the
        -- lab for both.
        if not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end

    return ids
end

-- -----------------------------------------------------------------------------
-- Attribution (8.3.4) and intake (8.6)
-- -----------------------------------------------------------------------------

--- A string, or nil when there is nothing in it.
local function filled(value)
    if type(value) ~= 'string' then return nil end

    local text = value:match('^%s*(.-)%s*$')
    return text ~= '' and text or nil
end

--- The owner a collected trace is filed under, or nil when it has none.
---
--- 8.3.4: the owner of a trace is always its source -- the person whose hidden
--- identifier it carries, or the weapon whose serial it does. A trace with
--- neither is a bug in the generation pipeline rather than an unattributed
--- item, which is exactly what `ck_fpd_evidence_owner_one` says by refusing to
--- store one. Answering nil here lets the route refuse the collection cleanly
--- instead of driving the insert into that constraint, where the officer would
--- be shown a generic internal error for a trace that simply has no owner.
---
--- A blank identifier counts as absent. It would satisfy the CHECK while
--- attributing the trace to nobody, which is worse than having no owner row:
--- the lab would then compare a sample against an empty profile and report an
--- exclusion that means nothing.
---
--- @param trace table|nil as the grid handed it over
--- @return table|nil { identifier, weaponSerial }
function Evidence.ownerOf(trace)
    local owner = type(trace) == 'table' and trace.owner or nil
    if type(owner) ~= 'table' then return nil end

    local identifier = filled(owner.identifier)
    local weaponSerial = filled(owner.weaponSerial)

    if not identifier and not weaponSerial then return nil end

    return { identifier = identifier, weaponSerial = weaponSerial }
end

--- Statuses the property room may accept an item from (8.6).
---
--- `released` and `destroyed` are terminal and deliberately absent: an item
--- whose disposition has been carried out does not come back.
---
--- The list lives here rather than in the route because both halves of the
--- two-step intake need it -- the accept path as the `from` list of its UPDATE,
--- and the rejection path as a gate before it writes to a chain that can never
--- be corrected (invariant 11).
Evidence.INTAKE_FROM = { 'collected', 'in_locker', 'checked_out', 'at_lab' }

--- May the property room record a decision about an item in this state?
function Evidence.canIntake(status)
    for index = 1, #Evidence.INTAKE_FROM do
        if Evidence.INTAKE_FROM[index] == status then return true end
    end

    return false
end

--- Render data for a piece of uncollected evidence lying in the world (8.1.6).
---
--- Everything a client needs to draw it and nothing else. No owner, no id that
--- could be used to ask about it, no quality.
---
--- There is no `revealed` flag here, and there is nothing to put one on: a
--- latent trace nobody has processed is not in the payload at all (8.4), and a
--- revealed one appears only in the privileged of the two lists `renderLists`
--- builds in `forensics/grid.lua`. Which of those two a client is sent is
--- decided in `Grid.push`, against the same permission a read would go through,
--- so visibility is a question of whether the row was sent and never a field a
--- client could read the other way round (8.11).
---
--- 8.1.6 names rotation as part of render data and this does not carry one, on
--- purpose: nothing in the generation pipeline observes a heading, so the only
--- value there is to send is a constant, and a constant in the payload is a
--- field that reads as truth and is not. See the note in `forensics/grid.lua`.
function Evidence.renderData(item)
    return {
        key = item.key,
        type = item.type,
        x = item.x,
        y = item.y,
        z = item.z,
        -- The prop, chosen by configuration from the type (`forensics.models`).
        -- Absent when the server has configured none, and `fredpd_forensics`
        -- draws a marker instead of guessing one.
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

--- How wide the sequence is, per kind of number.
local SEQUENCE_WIDTH <const> = { evidence = 6, scene = 4 }

--- The fixed half of a number, and the width of its sequence.
---
--- Numbering has to be unique per agency and year, which means the sequence has
--- to be read and used without anything slipping in between -- so the repo
--- computes it inside the same INSERT that writes the row, and needs the number
--- in two pieces to do that: a prefix it can concatenate and a width it can pad
--- to. `numberPrefix('evidence', 'lspd', 2026)` gives `LSPD-2026-` and 6, and
--- `prefix .. ('%06d'):format(sequence)` is byte-for-byte `evidenceNumber(...)`.
---
--- Keeping the format here rather than in the SQL is the point: there is one
--- definition of what a record number looks like, and the spec proves the two
--- ways of building it agree.
---
--- @param kind string 'evidence' or 'scene'
--- @param agencyShort string
--- @param year number
--- @return string|nil prefix
--- @return number|nil width
function Evidence.numberPrefix(kind, agencyShort, year)
    local width = SEQUENCE_WIDTH[kind]
    if not width then return nil end

    return ('%s%s%04d-'):format(
        tostring(agencyShort):upper(),
        kind == 'scene' and '-S-' or '-',
        year
    ), width
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

--- A flag, with nil read as false.
---
--- The grid writes all three of these on every trace it creates, but the lists
--- `shouldMerge` is called with in tests and from the lab-facing code are plain
--- tables that may carry none of them. Two traces that both say nothing about
--- their state are in the same state.
local function flag(value)
    return value == true
end

--- Should two traces be treated as one?
---
--- Same type, same owner, same state, close together. Without this, emptying a
--- magazine into a wall leaves thirty separate blood rows and the grid cell
--- becomes a performance problem rather than an investigation (spec 12).
---
--- **Why state is part of "the same trace".** A pool of blood somebody cleaned
--- an hour ago is at the same place, of the same type and from the same person
--- as the blood they are dripping now, and every other rule here says fold them
--- together. Folding them is the bug: the surviving row is the cleaned one, so
--- the fresh blood inherits `cleaned` -- a quarter of the DNA yield (8.1.4) --
--- and `latent`, which is invisibility. A murderer who mopped the floor would
--- get every wound they open afterwards hidden for free, in the one place in the
--- game where blood is supposed to give them away.
---
--- The fix lives here rather than in `forensics.placeIn`'s merge branch, and the
--- choice is not arbitrary. A merge branch that "reconciled" the three flags has
--- to pick an answer for a question with no good answer -- un-cleaning the old
--- pool hands the murderer's mopping back to them, keeping it cleaned is the
--- laundering, and there is only one `quality` and one `count` for what are
--- really two events. Two rows is the honest model: the cleaned pool stays
--- cleaned and still worth a quarter to luminol, the fresh blood is fresh, and
--- what a client is shown follows from each row's own state. `shouldMerge` is
--- also the one definition of "these are the same trace", which makes it the
--- place where the answer stays true for every caller instead of for one branch.
---
--- Compares squared distance to avoid a square root in the generation hot path.
function Evidence.shouldMerge(left, right, radius)
    if left.type ~= right.type then return false end
    if left.ownerKey ~= right.ownerKey then return false end

    -- Cleaned (8.10) decides what the lab gets out of the sample; latent and
    -- revealed (8.4) decide who may be told it is there. A trace in a different
    -- one of those states is a different trace, however close it landed.
    if flag(left.cleaned) ~= flag(right.cleaned) then return false end
    if flag(left.latent) ~= flag(right.latent) then return false end
    if flag(left.revealed) ~= flag(right.revealed) then return false end

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

--- Which of the three result languages each analysis speaks (8.7).
---
--- A table rather than a chain of `if`s because this is the one place that
--- decides what an analysis can conclude, and it should be readable as a list.
--- Every entry is a function of `facts` -- quality, contamination and counts of
--- hidden matches -- and none of it ever came from a client.
local ANALYSIS_RESULT <const> = {
    --- Contamination is what makes a mixture: someone walked through the scene
    --- and left their own DNA on top of the offender's (8.4).
    dna = function(facts)
        return Evidence.dnaResult(facts.quality, facts.contaminated and 2 or 1)
    end,

    --- Compared against the reference prints on file. A reference entry names
    --- its subject; a trace does not, which is what separates a comparison
    --- from a search.
    print_comparison = function(facts)
        return Evidence.comparisonResult((facts.referenceHits or 0) > 0, facts.quality)
    end,

    --- Searched against the print index. A hit is a candidate (8.1.3).
    print_search = function(facts)
        return Evidence.searchResult(facts.indexHits, facts.quality)
    end,

    --- NIBIN-style correlation: the barrel signature against everything on
    --- file. Also a search, and also only ever a lead.
    ballistics = function(facts)
        return Evidence.searchResult(facts.indexHits, facts.quality)
    end,

    --- Residue is only ever "consistent with having fired", never proof that
    --- this person fired this gun -- which is exactly what `candidate_match`
    --- means, so GSR speaks the search language rather than the comparison one.
    ---
    --- The only fact it has is the sample itself, and that is not an oversight.
    --- 8.2 is explicit that "a swab says this person fired something, never
    --- what", so the owner a swab is filed under carries an identifier and
    --- deliberately no weapon serial: there is nothing on file for it to be
    --- searched against, and a rule that looked for one -- as this did -- says
    --- `no_match` for every swab that can exist, which is the lab formally
    --- reporting that a suspect with residue all over their hands did not fire.
    ---
    --- What the swab measures is the residue level, and `forensics.claimGsr`
    --- stores that level as the item's quality. So the sample is the search: a
    --- level at all is the hit, and how much there was decides whether the
    --- result is worth anything, through the same insufficiency floor every
    --- other search goes through. The zero case cannot arise today -- a swab is
    --- only created when `gsr.present` says there is residue, and zero is below
    --- the floor in any event -- and it is written out rather than assumed, so
    --- that moving that floor cannot turn an empty swab into a lead.
    gsr = function(facts)
        return Evidence.searchResult(facts.quality > 0 and 1 or 0, facts.quality)
    end,

    --- A substance either identifies or the sample is too far gone to say.
    --- There is nothing to match it against, so there is no exclusion.
    drug_id = function(facts)
        return Evidence.comparisonResult(true, facts.quality)
    end,
}

--- Is this an analysis the lab performs?
---
--- The same table that decides results decides what may be requested, so a
--- request can never queue work that has no way of concluding. The input
--- validator has no enum type for list members, which is why this is checked
--- here rather than at the schema.
function Evidence.isAnalysis(analysis)
    return ANALYSIS_RESULT[analysis] ~= nil
end

--- The result of a completed analysis.
---
--- Every input is server-side: the sample's quality, whether the scene was
--- contaminated, and how many hidden profiles matched. The client sends none of
--- it and receives only the code this returns.
---
--- @param analysis string
--- @param facts table { quality, contaminated, referenceHits, indexHits }
--- @return string|nil result code, or nil when the analysis is not one we run
function Evidence.resultFor(analysis, facts)
    local rule = ANALYSIS_RESULT[analysis]
    if not rule then return nil end

    facts = facts or {}

    -- A missing quality is an unusable sample, not a crash. The database column
    -- is NOT NULL, so this only bites if a caller forgets to pass it -- and
    -- failing toward 'insufficient' is the safe direction.
    return rule({
        quality = facts.quality or 0,
        contaminated = facts.contaminated,
        referenceHits = facts.referenceHits,
        indexHits = facts.indexHits,
    })
end

--- Which forensic index a finished analysis adds its own profile to (8.8).
---
--- Only DNA, and only when a profile actually came out of the sample. 8.8's
--- trace indexes hold *unidentified crime-scene profiles*, so what goes in is a
--- profile the lab obtained, not the hidden truth behind an item nobody has
--- analysed. A partial profile still goes in -- a partial is searchable, and
--- 8.1.3 has already decided that a hit off any of these is a lead needing
--- confirmation, not an identification.
---
--- A mixture does not: 8.7 defines it as more than one contributor, and a
--- profile of two people is not a profile of either.
---
--- @return string|nil the `fpd_forensic_index.index_kind` to file it under
function Evidence.traceIndexFor(analysis, resultCode)
    if analysis ~= 'dna' then return nil end

    if resultCode == 'profile_obtained' or resultCode == 'partial_profile' then
        return 'dna_trace'
    end

    return nil
end

--- Is this result one a court may hear as an identification?
---
--- Used to decide whether a lead may be promoted. Kept as a function rather
--- than a comparison at each call site so the rule is in one place.
function Evidence.isCourtGrade(resultCode)
    return resultCode == 'identification' or resultCode == 'exclusion'
end

FredPD.Modules.evidence = Evidence
