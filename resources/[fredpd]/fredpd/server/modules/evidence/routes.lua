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
--- Claiming is destructive by design. The trace leaves the grid before the item
--- enters the database, so two officers cannot collect the same casing.
---
--- What that costs, plainly, because the handler below cannot pay it back: the
--- claim happens before the insert, and a refusal after it -- an unattributable
--- trace, or an insert that fails on a deadlock, a dropped connection or a
--- constraint -- leaves the trace gone from the grid with no row written. The
--- only 9 mm casing at a homicide can be lost to a transient database error, and
--- no officer can re-collect it because there is nothing left to collect. The
--- fix is a non-destructive claim plus a reservation, or a restore path in the
--- grid, and neither exists: `Grid.place` mints a new key, a new `createdAt` and
--- an unrevealed latent flag, so re-placing a taken trace would hand back a
--- younger, invisible copy of it. Until then this is a known hole, written down
--- rather than papered over.
---
--- @param src number
--- @param traceKey string the opaque key the client was given with render data
--- @return table|nil { type, quality, ageSeconds, decayPerHour, outdoors,
---   cleaned, owner = { identifier, weaponSerial } }. `raining` is *not* in the
---   shape: no claim produces it and the server tracks no weather, so the
---   weather half of `qualityAfter` (8.1.4) is inert -- see the note on
---   `claimTrace` in the forensics module.
FredPD.Evidence.claimTrace = FredPD.Evidence.claimTrace or function()
    return nil
end

--- The same, for the residue a shooter carries instead of leaves (8.2).
---
--- Gunshot residue is the one trace in 8.2 that is not in the world, so there is
--- no key for it and no grid cell it sits in: it is on a person, and what names
--- it is that person. The claim is otherwise identical -- it answers the shape
--- above or nil, it hands over hidden truth the client has never seen, and it is
--- destructive, so two officers cannot swab the same hands.
---
--- Registered by `fredpd`'s forensics routes, beside `claimTrace`. Until they
--- load there is nothing on anybody to collect and every swab is refused, which
--- is the same stance as above and for the same reason.
---
--- @param src number the officer taking the swab
--- @param targetSrc number the player being swabbed
--- @return table|nil the shape `claimTrace` answers, with `type = 'gsr'`
FredPD.Evidence.claimGsr = FredPD.Evidence.claimGsr or function()
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
---
--- `at` is where the officer has to be standing. A check-out to the lab, the
--- court or an investigator takes the item out of property-room storage, and
--- 8.6 puts that at the counter beside intake -- the same section that makes
--- the storage stashes open only at the property room access point. It cannot
--- be a context condition on the route, because it is true of three
--- destinations and not of the fourth: a locker deposit is the collecting
--- officer putting the item into a temporary locker (8.6), which is the one
--- transfer that happens away from the counter, and there is no placement kind
--- for a locker to check them against. So the check is per destination, in the
--- handler, against the same server-side placement test the route layer uses.
local TRANSFER <const> = {
    locker = { status = 'in_locker', action = 'deposit', from = { 'collected' } },
    lab = {
        status = 'at_lab', action = 'checkout',
        from = { 'in_property' }, at = 'property_terminal',
    },
    court = {
        status = 'checked_out', action = 'checkout',
        from = { 'in_property' }, at = 'property_terminal',
    },
    investigator = {
        status = 'checked_out', action = 'checkout',
        from = { 'in_property' }, at = 'property_terminal',
    },
}

--- Statuses an item may be accepted into the property room from (8.6). Both
--- halves of the two-step intake read it, so it lives in the service.
local INTAKE_FROM <const> = service.INTAKE_FROM

--- Which index an analysis searches, and against which hidden profile.
---
--- `referencesOnly` is the difference between a comparison and a search: a
--- reference entry names its subject, a trace entry does not (8.8).
---
--- There is deliberately no `dna` entry. 8.7 fixes what a DNA analysis may
--- conclude -- profile obtained, partial profile, mixture, no profile -- and
--- none of those are things an index can answer; "candidate match" is the
--- language of a database search, which is what `print_search` and `ballistics`
--- are. What 8.8 asks of DNA is the other direction: the profile the lab
--- obtained is filed as an unidentified crime-scene trace, which
--- `lab.analysis.complete` does below.
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
    auditDetail = function(input)
        -- 8.4 puts a checklist in front of a release, and the reason is what
        -- the officer signs it off with. `fpd_scenes` has no column for it --
        -- a scene records who released it and when -- so the audit log is
        -- where it is kept, which is also the log that cannot be edited
        -- afterwards (invariant 11).
        return { reason = text(input.reason) }
    end,
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

--- Where a collection's hidden truth comes from, by what the call named.
---
--- Two sources, one act. A trace lies in the world and is named by the opaque
--- key it was streamed with; gunshot residue is on a person and is named by that
--- person's server id, because 8.2 puts it on "shooter's hands and clothes" and
--- there is nothing in the grid to key it by. Both claims answer the same shape,
--- both are destructive, and both range-check against the server's copy of where
--- everybody is standing -- so from here down there is one collection, which is
--- the property 8.6 actually needs: one insert, one owner row, one first link of
--- the custody chain, in one transaction.
---
--- Exactly one of the two, and the server decides that rather than the schema:
--- the validator can say "an optional string" and "an optional integer" and
--- cannot say "one of these". Neither is a call that names nothing to collect;
--- both is a call that has not decided what it is doing, and guessing which one
--- it meant would be this file inventing an intent (invariant 1).
---
--- The `targetId` half has no caller anywhere in the product yet: no client
--- sends the field, so no swab can be taken and the residue path below is
--- unreachable. The gap is in `fredpd_forensics` -- there is no ox_target option
--- on a player -- and in the MDT's collect form, not here. Said once more where
--- somebody reading this file would otherwise assume the feature is live.
---
--- @return table|nil trace, or nil when there was nothing to claim
--- @return table|nil refusal, when the call named neither source or both
local function claimFor(session, input)
    local byTrace = input.traceKey ~= nil
    local byTarget = input.targetId ~= nil

    if not byTrace and not byTarget then
        return nil, route.refuse(FredPD.ErrorCode.INVALID, { traceKey = 'required' })
    end

    if byTrace and byTarget then
        return nil, route.refuse(FredPD.ErrorCode.INVALID, { targetId = 'not_allowed' })
    end

    if byTrace then
        return FredPD.Evidence.claimTrace(session.src, input.traceKey), nil
    end

    return FredPD.Evidence.claimGsr(session.src, input.targetId), nil
end

route.define({
    name = 'evidence.collect',
    perm = 'forensics.evidence.collect',
    schema = 'EvidenceCollect',
    -- No access point: collection happens where the evidence is, which is the
    -- point of collecting it. What replaces the terminal as the control is the
    -- claim below -- the server will not collect a trace the player is not
    -- standing next to, or residue off a suspect they are not standing next to,
    -- because the grid and the residue table both refuse to give it up.
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
                return route.refuse(FredPD.ErrorCode.CONFLICT, { sceneId = 'scene_released' })
            end
        end

        -- A trace out of the grid, or the residue off a suspect's hands (8.2).
        -- One refusal for every way either of them can come to nothing -- no
        -- such key, no such player, somebody got there first, out of reach,
        -- nothing on them, residue that has already decayed -- because a
        -- collection that reported *why* it found nothing is a detector an
        -- officer could walk around pointing at people (8.11).
        local trace, refusal = claimFor(session, input)

        if refusal then return refusal end
        if not trace then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        -- Every trace is left by somebody or by something: 8.3.4 makes the
        -- owner the source player's hidden identifier, and a casing carries the
        -- weapon instead. One with neither is a bug in the generation pipeline,
        -- which is what `ck_fpd_evidence_owner_one` says by refusing to store
        -- it. Refused here rather than in the transaction, so the officer is
        -- told the trace cannot be attributed instead of being shown a generic
        -- server error -- and so the item is not written at all, which is the
        -- right outcome: an item with no owner would be analysed against an
        -- empty profile and come back as an exclusion that means nothing.
        local owner = service.ownerOf(trace)

        if not owner then
            -- A claim handed over something it should never produce. The console
            -- is where an operator can see it; the type and the key name the
            -- trace and disclose nobody. A swab cannot reach here -- `claimGsr`
            -- refuses residue it cannot attribute -- so the key is the one that
            -- is printed, and it is nil on the path that has none.
            print(('[fredpd] evidence.collect: unattributed trace %s (%s)')
                :format(tostring(input.traceKey), tostring(trace.type)))

            return route.refuse(FredPD.ErrorCode.INVALID, { traceKey = 'unattributed' })
        end

        -- Contamination is read from the entry log and never from the collecting
        -- officer's word for it (8.4): anyone who walked the perimeter without
        -- protective equipment degrades everything taken from it.
        --
        -- That is the design and not yet the behaviour. Nothing in the product
        -- writes `fpd_scene_entries` -- there is no perimeter zone in
        -- `fredpd_forensics` and no route that logs an entry -- so this COUNT is
        -- zero on every scene that exists and the contamination term is
        -- currently dead here and at `lab.analysis.complete`. 8.4's entry log is
        -- an unimplemented [M], not a wired feature, and the read stays because
        -- the query is what the log will feed, not because it reports anything
        -- today.
        local contaminated = repo.unprotectedEntries(input.sceneId) > 0

        -- No `raining`: the claim shape does not carry one and the server tracks
        -- no weather, so passing it would be passing nil. `outdoors` is passed
        -- and is nil too, for now -- nothing sets it in the grid. Both halves of
        -- 8.1.4's weather term arrive together or not at all, and when they do
        -- this is the call that grows the field back.
        local quality = service.qualityAfter(trace.quality or 100, trace.ageSeconds or 0, {
            decayPerHour = trace.decayPerHour,
            outdoors = trace.outdoors,
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
        }, owner, session.discordId)

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
            -- The same states the accept path allows, checked before anything
            -- is written. The accept path enforces them inside its UPDATE; a
            -- rejection changes no status, so without this it would accept an
            -- item in any state at all -- including released and destroyed,
            -- which `INTAKE_FROM` deliberately excludes. The chain is
            -- append-only (invariant 11), so an entry written against an item
            -- whose disposition has already been carried out can never be
            -- taken back.
            if not service.canIntake(item.status) then
                return route.refuse(FredPD.ErrorCode.CONFLICT, { status = item.status })
            end

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
    -- The access point is not here because it depends on the destination: see
    -- `TRANSFER` above and the check at the top of the handler.
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

        -- A check-out empties a storage location, so it happens at the property
        -- room counter (8.6). The client names the placement it is using and
        -- the server checks the player is genuinely within its radius (3.10) --
        -- without this an item could be taken out of the vault from anywhere in
        -- the world, which is the one thing a property room is for.
        if move.at then
            if type(input.placementId) ~= 'number' then
                return route.refuse(FredPD.ErrorCode.CONTEXT, { placementId = 'required' })
            end

            if not FredPD.Core.placements.playerIsAt(session.src, input.placementId, move.at) then
                return route.refuse(FredPD.ErrorCode.CONTEXT, { placementId = 'not_allowed' })
            end
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
    -- On duty, but from anywhere: a request comes from a case, raised by the
    -- investigator working it (8.7), and 1.4 limits the lab terminal to the
    -- analysis itself. Asking for work is not doing it.
    context = { onDuty = true },
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
    -- Analysis happens at the lab bench: 1.4 limits "analysis, technical
    -- review" to the lab terminal, and 8.7 makes the turnaround the time the
    -- analyst spends on it. A clock that could be started from a car would be a
    -- countdown, not a workload.
    context = { onDuty = true, accessPoint = 'lab_terminal' },
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
    -- Where the analysis was started, and for the same reason (1.4, 8.7).
    context = { onDuty = true, accessPoint = 'lab_terminal' },
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
            -- Zero on every scene until 8.4's entry log is written by something;
            -- see the same read in `evidence.collect` for why.
            contaminated = repo.unprotectedEntries(facts.sceneId) > 0,
            referenceHits = referenceHits,
            indexHits = indexHits,
            -- Read by no rule in `service.lua` today: the GSR rule that used to
            -- ask for it now measures the residue level instead, which is the
            -- only fact a swab carries (8.2, and the note on `ANALYSIS_RESULT
            -- .gsr`). Passed on because it is hidden truth about the item that a
            -- future rule would ask for by this name, and it costs one nil test.
            hasWeapon = facts.weaponSerial ~= nil,
        })

        if not result then
            return route.refuse(FredPD.ErrorCode.INVALID, { analysis = 'not_supported' })
        end

        -- The timer is checked in the UPDATE against the database's clock, so an
        -- analyst who calls this early changes nothing and is told to wait.
        if repo.completeAnalysis(session.agencyId, input.id, result, text(input.observations)) == 0 then
            -- Three conditions in one statement, so zero rows does not say
            -- which. An analysis cancelled under the analyst, or finished by
            -- the automatic mode while they were writing, must not be reported
            -- as a turnaround that has not elapsed: that is a wait which will
            -- never end, and they would sit there for it.
            local blocker = repo.completionBlocker(session.agencyId, input.id)

            if not blocker then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

            if blocker.status ~= 'in_progress' then
                return route.refuse(FredPD.ErrorCode.CONFLICT, { status = blocker.status })
            end

            -- MariaDB answers a boolean expression with 1 and 0.
            if not (blocker.elapsed == true or blocker.elapsed == 1) then
                return route.refuse(FredPD.ErrorCode.CONFLICT, { dueAt = 'not_elapsed' })
            end

            -- In progress, due, and still nothing written: the transaction did
            -- not commit. That is a server fault and is reported as one rather
            -- than as something the analyst did wrong.
            return route.refuse(FredPD.ErrorCode.INTERNAL)
        end

        -- 8.8: the profile the lab obtained joins the trace index as an
        -- unidentified crime-scene profile, which is what later correlations
        -- and confirmations search. The copy happens inside the statement, so
        -- the profile itself never reaches this file.
        local indexKind = service.traceIndexFor(facts.analysis, result)

        if indexKind then
            repo.indexTraceProfile(session.agencyId, facts.evidenceId, indexKind, session.discordId)
        end

        return { id = input.id, analysis = facts.analysis, resultCode = result }
    end,
})
