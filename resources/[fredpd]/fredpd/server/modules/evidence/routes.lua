--- Evidence, property room and lab routes (spec 8).
---
--- Three things are decided here and nowhere else, and each of them is a thing
--- the reference script let a client decide:
---
---   * **What was collected.** The type and the owner of a trace come from the
---     server-side grid, not from the call. A client that could name the type
---     could collect a casing as a blood swab; one that could name the owner
---     could frame anybody.
---   * **Where an item is.** Status moves through a fixed table of legal
---     transitions, and everything entering the property room goes through the
---     terminal, standing at it (8.6).
---   * **What the lab found.** `lab.analysis.complete` computes the result from
---     hidden truth the client has never seen and never will. The call carries
---     observations -- how the analyst worked -- and never a conclusion.

local route = FredPD.Core.route
local service = FredPD.Modules.evidence
local repo = FredPD.Repo.evidence

-- -----------------------------------------------------------------------------
-- The trace grid (8.3)
-- -----------------------------------------------------------------------------

FredPD.Evidence = FredPD.Evidence or {}

--- Where a collected trace's hidden truth comes from.
---
--- The generation pipeline and the server-side spatial grid it keeps belong to
--- `fredpd_forensics`, which registers a claim function here when it loads.
--- Until it does there is nothing in the world to collect, and every collection
--- is refused rather than served with an invented owner: fabricating that one
--- fact would undo the whole of section 8.
---
--- Claiming is destructive by design. The trace leaves the grid as the item
--- enters the database, so two officers cannot collect the same casing, and a
--- failed insert does not leave a half-collected trace behind.
---
--- @param src number
--- @param traceKey string the opaque key the client was given with render data
--- @return table|nil { type, quality, ageSeconds, decayPerHour, outdoors,
---   raining, cleaned, owner = { identifier, weaponSerial } }
FredPD.Evidence.claimTrace = FredPD.Evidence.claimTrace or function()
    return nil
end

-- -----------------------------------------------------------------------------
-- Shared rules
-- -----------------------------------------------------------------------------

--- May this session be shown what the lab concluded?
---
--- Being allowed to look at an evidence item is not being cleared to read the
--- analysis of it (8.11). Every read of an analysis goes through this.
local function canSeeResults(session)
    return FredPD.Core.perms.satisfies(session.permissions, 'lab.queue.view')
end

--- Shapes a list of analyses for one reader.
local function analysesFor(rows, session)
    local visible = canSeeResults(session)

    for index = 1, #rows do
        rows[index] = service.analysisPublic(rows[index], visible)
    end

    return rows
end

--- Shapes a list of evidence rows. Nothing reaches a client any other way.
local function publicAll(rows)
    for index = 1, #rows do
        rows[index] = service.public(rows[index])
    end

    return rows
end

--- Where a transfer may send an item, what that makes its status, what the
--- custody log calls it, and which statuses it is legal from.
---
--- An allowlist in code (invariant 1): the client names a destination, never a
--- column and never a status. The `from` list is what makes the chain a chain --
--- an item at the lab cannot be deposited in a locker without coming back
--- through the property room first.
---
--- Note what is absent: no destination here sets `in_property`. Everything
--- entering the property room goes through `evidence.intake`, at the terminal,
--- which is the only place a storage location is assigned (8.6).
local TRANSFER <const> = {
    locker = { status = 'in_locker', action = 'deposit', from = { 'collected' } },
    lab = { status = 'at_lab', action = 'checkout', from = { 'in_property' } },
    court = { status = 'checked_out', action = 'checkout', from = { 'in_property' } },
    investigator = { status = 'checked_out', action = 'checkout', from = { 'in_property' } },
}

--- Statuses an item may be accepted into the property room from.
---
--- `released` and `destroyed` are terminal and deliberately not here: an item
--- whose disposition has been carried out does not come back.
local INTAKE_FROM <const> = { 'collected', 'in_locker', 'checked_out', 'at_lab' }

--- Which index an analysis searches, and against which hidden profile.
---
--- `referencesOnly` is the difference between a comparison and a search: a
--- reference entry names its subject, a trace entry does not (8.8).
local ANALYSIS_INDEX <const> = {
    print_comparison = { kind = 'fingerprint', profile = 'fingerprint', referencesOnly = true },
    print_search = { kind = 'fingerprint', profile = 'fingerprint' },
    ballistics = { kind = 'ballistics', profile = 'barrelSignature' },
}

--- Trims a string to nil when it is blank, so an empty box is not stored as one.
local function text(value)
    if type(value) ~= 'string' then return nil end

    local trimmed = value:match('^%s*(.-)%s*$')
    return trimmed ~= '' and trimmed or nil
end

-- =============================================================================
-- Scenes (8.4)
-- =============================================================================

route.define({
    name = 'scene.create',
    perm = 'forensics.scene.create',
    schema = 'SceneCreate',
    context = { onDuty = true },
    writes = true,
    audit = 'evidence.scene.created',
    subjectType = 'scene',
    auditDetail = function(input)
        return { caseNumber = input.caseNumber, radius = input.radius }
    end,
    handler = function(session, input)
        -- The perimeter is where the officer opening it is standing, read from
        -- the server's copy of their position. Taking coordinates from the call
        -- would let a client throw a scene around a location it has never been
        -- to -- and a scene is what makes everything inside it evidence.
        local ped = GetPlayerPed(session.src)
        if ped == 0 then return route.refuse(FredPD.ErrorCode.CONTEXT) end

        local position = GetEntityCoords(ped)

        local id = repo.createScene(session.agencyId, {
            caseNumber = text(input.caseNumber),
            x = position.x,
            y = position.y,
            z = position.z,
            radius = input.radius or 25.0,
        }, session.discordId)

        if not id then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = id, scene = repo.getScene(session.agencyId, id) }
    end,
})

route.define({
    name = 'scene.release',
    perm = 'forensics.scene.release',
    schema = 'SceneRelease',
    context = { onDuty = true },
    writes = true,
    -- Releasing the perimeter ends the one window in which the scene can be
    -- worked: whatever was not collected before this is gone. Spec 4.2 puts a
    -- release behind a fresh permission snapshot for exactly this reason.
    sensitive = true,
    audit = 'evidence.scene.released',
    subjectType = 'scene',
    handler = function(session, input)
        local scene = repo.getScene(session.agencyId, input.id)
        if not scene then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        -- Already released. Reported as a conflict rather than quietly
        -- succeeding, so the second officer sees that somebody got there first
        -- instead of believing they released it.
        if repo.releaseScene(session.agencyId, input.id, session.discordId) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = input.id }
    end,
})

route.define({
    name = 'scene.list',
    perm = 'forensics.scene.create',
    schema = 'SceneList',
    audit = 'evidence.scene.listed',
    auditDetail = function(_input, result)
        return { count = #result.scenes }
    end,
    handler = function(session, input)
        return {
            scenes = repo.listScenes(session.agencyId, {
                status = input.status,
                caseNumber = text(input.caseNumber),
                limit = input.limit,
            }),
        }
    end,
})

-- =============================================================================
-- Collection (8.4, 8.5)
-- =============================================================================

route.define({
    name = 'evidence.collect',
    perm = 'forensics.evidence.collect',
    schema = 'EvidenceCollect',
    -- No access point: collection happens where the evidence is, which is the
    -- point of collecting it. What replaces the terminal as the control is the
    -- claim below -- the server will not collect a trace the player is not
    -- standing next to, because the grid refuses to give it up.
    context = { onDuty = true },
    limit = { per = 30, window = 60 },
    writes = true,
    audit = 'evidence.collected',
    subjectType = 'evidence',
    auditDetail = function(input, result)
        -- The item's number and packaging, never its type paired with a person,
        -- and never the owner: the audit log is readable by more people than
        -- the lab result is (invariant 11, 8.11).
        return { evidenceNumber = result.item.evidenceNumber, packaging = input.packaging }
    end,
    handler = function(session, input)
        local scene = nil

        if input.sceneId then
            scene = repo.getScene(session.agencyId, input.sceneId)
            if not scene then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

            -- A released scene is finished. Attaching an item to it afterwards
            -- would put something into the record that nobody can account for
            -- having been inside the perimeter.
            if scene.status ~= 'open' then
                return route.refuse(FredPD.ErrorCode.CONFLICT, { sceneId = 'released' })
            end
        end

        local trace = FredPD.Evidence.claimTrace(session.src, input.traceKey)
        if not trace then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        -- Contamination is read from the entry log, not from the collecting
        -- officer's word for it (8.4): anyone who walked the perimeter without
        -- protective equipment degrades everything taken from it.
        local contaminated = repo.unprotectedEntries(input.sceneId) > 0

        local quality = service.qualityAfter(trace.quality or 100, trace.ageSeconds or 0, {
            decayPerHour = trace.decayPerHour,
            outdoors = trace.outdoors,
            raining = trace.raining,
            cleaned = trace.cleaned,
            contaminated = contaminated,
        })

        local item = repo.insertEvidence(session.agencyId, {
            sceneId = input.sceneId,
            caseNumber = text(input.caseNumber) or (scene and scene.caseNumber),
            -- From the grid, never from the call.
            type = trace.type,
            packaging = input.packaging,
            markerNumber = input.markerNumber,
            description = text(input.description),
            quality = quality,
            fromParty = scene and scene.sceneNumber or nil,
        }, trace.owner or {}, session.discordId)

        if not item then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = item.id, item = service.public(item) }
    end,
})

-- =============================================================================
-- Property room (8.6)
-- =============================================================================

route.define({
    name = 'evidence.intake',
    perm = 'evidence.item.intake',
    schema = 'EvidenceIntake',
    -- Spec 8.6: intake happens at the property room terminal, and the route
    -- layer checks the player is genuinely standing at it rather than taking
    -- the client's word for which placement it is using.
    context = { onDuty = true, accessPoint = 'property_terminal' },
    writes = true,
    -- Custody passes here. A stale permission snapshot is not good enough
    -- authority to take responsibility for somebody else's evidence (4.2).
    sensitive = true,
    audit = 'evidence.intake',
    subjectType = 'evidence',
    auditDetail = function(input)
        return { accepted = input.accepted, storageLocation = input.storageLocation }
    end,
    handler = function(session, input)
        local item = repo.getEvidence(session.agencyId, input.id)
        if not item then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        local holder = repo.currentHolder(input.id)

        -- Rejected at the counter: the seal is broken, the description does not
        -- match, the paperwork is wrong. The item does not move, and the reason
        -- goes into the chain where the officer who brought it can read it.
        if not input.accepted then
            repo.appendCustody({
                evidenceId = input.id,
                action = 'intake',
                fromParty = holder,
                toParty = holder,
                reason = text(input.reason),
            }, session.discordId)

            return { id = input.id, accepted = false }
        end

        local storage = text(input.storageLocation)
        if not storage then
            return route.refuse(FredPD.ErrorCode.INVALID, { storageLocation = 'required' })
        end

        local moved = repo.setEvidenceStatus(
            session.agencyId, input.id, 'in_property', storage, INTAKE_FROM
        )

        if moved == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { status = item.status })
        end

        repo.appendCustody({
            evidenceId = input.id,
            action = 'intake',
            fromParty = holder,
            toParty = storage,
            reason = text(input.reason),
        }, session.discordId)

        return { id = input.id, accepted = true }
    end,
})

route.define({
    name = 'evidence.transfer',
    perm = 'evidence.item.transfer',
    schema = 'EvidenceTransfer',
    context = { onDuty = true },
    writes = true,
    sensitive = true,
    audit = 'evidence.transferred',
    subjectType = 'evidence',
    auditDetail = function(input)
        return { destination = input.destination }
    end,
    handler = function(session, input)
        local move = TRANSFER[input.destination]
        if not move then
            return route.refuse(FredPD.ErrorCode.INVALID, { destination = 'not_allowed' })
        end

        local item = repo.getEvidence(session.agencyId, input.id)
        if not item then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        local reason = text(input.reason)
        if not reason then
            return route.refuse(FredPD.ErrorCode.INVALID, { reason = 'required' })
        end

        local holder = repo.currentHolder(input.id)

        -- The legal-from list is enforced in the UPDATE, so an item that moved
        -- between the read above and this write is refused rather than dragged
        -- backwards through the chain.
        if repo.setEvidenceStatus(session.agencyId, input.id, move.status, nil, move.from) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { status = item.status })
        end

        repo.appendCustody({
            evidenceId = input.id,
            action = move.action,
            fromParty = holder,
            -- Who received it, in words, for the chain. The signature underneath
            -- it is the session's, never anything the call supplied (8.6).
            toParty = text(input.toParty) or input.destination,
            reason = reason,
        }, session.discordId)

        return { id = input.id, status = move.status }
    end,
})

route.define({
    name = 'evidence.custody',
    perm = 'evidence.item.view',
    schema = 'EvidenceCustody',
    audit = 'evidence.custody.read',
    subjectType = 'evidence',
    handler = function(session, input)
        -- Scoped before the chain is read: without this, the custody of any
        -- agency's item would be readable by id (invariant 4).
        if not repo.getEvidence(session.agencyId, input.id) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id, custody = repo.custodyFor(input.id) }
    end,
})

-- =============================================================================
-- Reading evidence (8.11)
-- =============================================================================

route.define({
    name = 'evidence.list',
    perm = 'evidence.item.view',
    schema = 'EvidenceList',
    audit = 'evidence.listed',
    auditDetail = function(input, result)
        return { count = #result.items, status = input.status }
    end,
    handler = function(session, input)
        local search = text(input.search)

        return {
            items = publicAll(repo.listEvidence(session.agencyId, {
                status = input.status,
                type = input.type,
                sceneId = input.sceneId,
                caseNumber = text(input.caseNumber),
                search = search and search:lower() or nil,
                limit = input.limit,
            })),
        }
    end,
})

route.define({
    name = 'evidence.get',
    perm = 'evidence.item.view',
    schema = 'EvidenceGet',
    audit = 'evidence.read',
    subjectType = 'evidence',
    handler = function(session, input)
        local item = repo.getEvidence(session.agencyId, input.id)
        if not item then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        return {
            id = input.id,
            item = service.public(item),
            -- The analyses are listed for anyone who may see the item -- knowing
            -- it is at the lab is part of knowing where it is -- but what they
            -- found is withheld from readers without a lab permission.
            analyses = analysesFor(repo.analysesForEvidence(session.agencyId, input.id), session),
        }
    end,
})

-- =============================================================================
-- The lab (8.7)
-- =============================================================================

route.define({
    name = 'lab.request.create',
    perm = 'lab.request.create',
    schema = 'LabRequestCreate',
    writes = true,
    limit = { per = 10, window = 60 },
    audit = 'lab.request.created',
    subjectType = 'lab_request',
    auditDetail = function(input, result)
        return { priority = input.priority, queued = result.queued }
    end,
    handler = function(session, input)
        local ids, reason = service.parseIds(input.evidenceIds, 25)
        if not ids then return route.refuse(FredPD.ErrorCode.INVALID, { evidenceIds = reason }) end

        -- Every item must be this agency's. Counting rather than fetching keeps
        -- it to one query, and a mismatch means at least one id was somebody
        -- else's -- which is a probe, not a typo, so nothing is written.
        if repo.countEvidenceIn(session.agencyId, ids) ~= #ids then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { evidenceIds = 'unknown' })
        end

        local requested, seen = {}, {}

        for index = 1, #input.analyses do
            local analysis = input.analyses[index]

            if not service.isAnalysis(analysis) then
                return route.refuse(FredPD.ErrorCode.INVALID, { analyses = 'not_allowed' })
            end

            if not seen[analysis] then
                seen[analysis] = true
                requested[#requested + 1] = analysis
            end
        end

        if #requested == 0 then
            return route.refuse(FredPD.ErrorCode.INVALID, { analyses = 'required' })
        end

        local queued = {}

        for itemIndex = 1, #ids do
            for analysisIndex = 1, #requested do
                queued[#queued + 1] = {
                    evidenceId = ids[itemIndex],
                    analysis = requested[analysisIndex],
                }
            end
        end

        local id = repo.createLabRequest(session.agencyId, {
            caseNumber = text(input.caseNumber),
            priority = input.priority or 'routine',
            justification = text(input.justification),
        }, queued, session.discordId)

        if not id then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = id, queued = #queued }
    end,
})

route.define({
    name = 'lab.queue',
    perm = 'lab.queue.view',
    schema = 'LabQueue',
    audit = 'lab.queue.read',
    auditDetail = function(_input, result)
        return { count = #result.queue }
    end,
    handler = function(session, input)
        return {
            queue = analysesFor(repo.labQueue(session.agencyId, {
                status = input.status,
                analysis = input.analysis,
                -- "Mine" is the session's own signature. An analyst id arriving
                -- in the call would let anyone read another analyst's workload.
                mine = input.mine and session.discordId or nil,
                limit = input.limit,
            }), session),
        }
    end,
})

route.define({
    name = 'lab.analysis.start',
    perm = 'lab.analysis.perform',
    schema = 'LabAnalysisStart',
    writes = true,
    audit = 'lab.analysis.started',
    subjectType = 'lab_analysis',
    auditDetail = function(_input, result)
        return { analysis = result.analysis }
    end,
    handler = function(session, input)
        local analysis = repo.getAnalysis(session.agencyId, input.id)
        if not analysis then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        -- Turnaround is decided here, from the analysis and the priority on the
        -- request, and written as a due time. Neither the wait nor the clock is
        -- anything the client has a say in (8.7).
        local seconds = service.turnaroundSeconds(
            analysis.analysis, analysis.priority, FredPD.Config.server.lab
        )

        if repo.startAnalysis(session.agencyId, input.id, session.discordId, seconds) == 0 then
            -- Already started, or somebody else took it off the queue first.
            return route.refuse(FredPD.ErrorCode.CONFLICT, { status = analysis.status })
        end

        return { id = input.id, analysis = analysis.analysis, seconds = seconds }
    end,
})

route.define({
    name = 'lab.analysis.complete',
    perm = 'lab.analysis.perform',
    schema = 'LabAnalysisComplete',
    writes = true,
    -- This is the moment a result comes into existence. Spec 4.2: a release
    -- needs a permission snapshot that is actually current.
    sensitive = true,
    audit = 'lab.analysis.completed',
    subjectType = 'lab_analysis',
    auditDetail = function(_input, result)
        -- The analysis, never the result. The audit log is readable by more
        -- people than the conclusion is, and a log that copies the record
        -- defeats the access control on the record (invariant 11).
        return { analysis = result.analysis }
    end,
    handler = function(session, input)
        -- Hidden truth (8.1). Everything below reads from `facts` to reach a
        -- result code; nothing derived from it is returned, audited or pushed.
        local facts = repo.hiddenFacts(session.agencyId, input.id)
        if not facts then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        if facts.status ~= 'in_progress' then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { status = facts.status })
        end

        -- The analyst who took the work signs the result. Technical review by a
        -- second analyst is a separate permission and a later route (8.7); this
        -- is not it, and finishing somebody else's analysis is not review.
        if facts.assignedTo ~= session.discordId then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN)
        end

        local lookup = ANALYSIS_INDEX[facts.analysis]
        local referenceHits, indexHits = 0, 0

        if lookup then
            -- The profiles are compared inside the database and only a count
            -- comes back, so no hidden value is ever in a variable a response
            -- could pick up by accident.
            local hits = repo.indexHits(
                session.agencyId, lookup.kind, facts[lookup.profile], lookup.referencesOnly
            )

            if lookup.referencesOnly then
                referenceHits = hits
            else
                indexHits = hits
            end
        end

        local result = service.resultFor(facts.analysis, {
            quality = facts.quality,
            contaminated = repo.unprotectedEntries(facts.sceneId) > 0,
            referenceHits = referenceHits,
            indexHits = indexHits,
            hasWeapon = facts.weaponSerial ~= nil,
        })

        if not result then
            return route.refuse(FredPD.ErrorCode.INVALID, { analysis = 'not_supported' })
        end

        -- The timer is checked in the UPDATE against the database's clock, so an
        -- analyst who calls this early changes nothing and is told to wait.
        if repo.completeAnalysis(session.agencyId, input.id, result, text(input.observations)) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { dueAt = 'not_elapsed' })
        end

        return { id = input.id, analysis = facts.analysis, resultCode = result }
    end,
})
