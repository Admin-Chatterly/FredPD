--- Intelligence routes (spec 10).
---
--- Everything PD-Span did, behind FredPD's route layer: a Discord-derived
--- permission per route, agency scoping done on the server, optimistic locking
--- on every edit, and an audit entry on every write.
---
--- Two things are stricter here than in PD-Span, both deliberately:
---
---   * Reads of the register are audited. PD-Span could not answer "who looked
---     at this?" for any record; spec 11 requires that it can.
---   * The source of a note from an informant, a wiretap or surveillance is
---     withheld from readers without `intel.source.view`. The intelligence
---     stays readable; where it came from does not.
---
--- And every record goes through the access check (4.5, invariant 4): a
--- person, organisation, case or note carries a classification, compartments
--- and perhaps a seal, and the permission to open the register is not
--- clearance for everything in it. Lists are filtered (hidden or stubbed, as
--- the compartment says), a single read of a record the reader may not see is
--- refused, and a link to one -- a membership, an associate, a case link, a
--- note on a person -- is left off, because the link says who is tied to
--- whom. Writes check the record they touch the same way, so an edit cannot
--- tell a reader that a record they may not see exists.

local route = FredPD.Core.route
local service = FredPD.Modules.intel
local repo = FredPD.Repo.intel

local PERSON <const>, ORG <const>, NOTE <const>, CASE <const> = 'intel_person', 'intel_org', 'intel_note', 'intel_case'

local function access() return FredPD.Repo.access end

--- The ids among `records` (`{ id, classification }`) this reader may read in
--- full. A record they would see only as a stub is not among them.
local function visibleIds(session, recordType, records)
    local ids = {}
    for _, row in ipairs(access().filterSearch(session, recordType, records)) do
        if row.restricted ~= true then ids[row.id] = true end
    end
    return ids
end

--- The rows of a list whose linked record (`idField`) the reader may read in
--- full; the rest are left off with no gap.
local function onlyReadable(session, recordType, rows, idField, classificationField)
    local linked = service.linkedRecords(rows, idField, classificationField)
    if #linked == 0 then return rows end
    return service.keepLinked(rows, idField, visibleIds(session, recordType, linked))
end

--- The ids among `records` this reader may read in full, for a count or a
--- filter that shows nothing of them -- the same answer, without an audit
--- row for records nobody opened.
local function countableIds(session, recordType, records)
    if #records == 0 then return {} end
    return access().readableIds(session, recordType, records)
end

--- One record, as this reader may read it, or the refusal to send.
---
--- A record this reader may be told of (a stub) is `restricted`; one they may
--- not is answered exactly as one that does not exist -- the persons module's
--- rule (`refusalCode`), so walking ids cannot find a hidden record (4.5).
---
--- `fields`, when given, is `{ [name] = true }`: the field the refusal names,
--- as `restricted` or `unknown` to match the code.
local function readable(session, recordType, row, fields)
    local function refuse(stub)
        local named
        if fields then
            named = {}
            for name in pairs(fields) do named[name] = stub and 'restricted' or 'unknown' end
        end
        return nil, route.refuse(stub and FredPD.ErrorCode.RESTRICTED or FredPD.ErrorCode.NOT_FOUND, named)
    end

    if not row then return refuse(false) end

    local allowed = access().read(session, recordType, row)
    if allowed then return allowed end

    -- `row` still carries what `read` attached, so this decides the refusal
    -- without touching the access tables again.
    return refuse(FredPD.Modules.access.visibility(access().reader(session), row) == 'stub')
end

--- The record a write names, when it exists and this reader may read it.
local function mustRead(session, recordType, id)
    local getter = ({
        [PERSON] = repo.getPerson, [ORG] = repo.getOrg, [CASE] = repo.getCase, [NOTE] = repo.getNote,
    })[recordType]

    return readable(session, recordType, getter(session.agencyId, id))
end

--- Every record a write attaches something to, checked in turn.
--- @return table|nil refusal
local function mustReadAll(session, targets)
    for _, target in ipairs(targets) do
        if target[2] then
            local row, refusal = mustRead(session, target[1], target[2])
            if not row then return refusal end
        end
    end
    return nil
end

--- May this session see where protected intelligence came from?
local function canSeeSource(session)
    return FredPD.Core.perms.satisfies(session.permissions, 'intel.source.view')
end

--- Applies source redaction across a list of notes. A 4.5 stub has no source
--- and passes through as it is.
local function redactAll(notes, session)
    local visible = canSeeSource(session)

    for index = 1, #notes do
        notes[index] = service.redactSource(notes[index], visible)
    end

    return notes
end

--- The notes on a person, organisation or case that this reader may read in
--- full: a stub among them would still say there is more on this subject.
local function readableNotes(session, notes)
    return redactAll(onlyReadable(session, NOTE, notes, 'id', 'classification'), session)
end

--- Evidence shown on one record, kept only where the reader may read every
--- other record it hangs on too (4.5: attachments inherit the record's
--- access control). `own` is the record being viewed, already checked.
local function readableEvidence(session, rows, own)
    for _, side in ipairs({ { 'person', PERSON }, { 'org', ORG }, { 'case', CASE } }) do
        if side[1] ~= own then
            rows = onlyReadable(session, side[2], rows, side[1] .. 'Id', side[1] .. 'Classification')
        end
    end
    for _, row in ipairs(rows) do
        row.personClassification, row.orgClassification, row.caseClassification = nil, nil, nil
    end
    return rows
end

--- The ids of a list's rows that are not stubs.
local function idsOf(rows)
    local ids = {}
    for _, row in ipairs(rows) do
        if row.restricted ~= true and row.id ~= nil then ids[#ids + 1] = row.id end
    end
    return ids
end

--- For a list filtered by tag: the people or organisations it is on,
--- counting only the notes this reader may read -- a tag on a note they may
--- not read would otherwise pick out who it is about.
local TAGGED_NOTES <const> = 2000
local function taggedParents(session, tag, column)
    local notes = repo.taggedNotes(session.agencyId, tag, column, TAGGED_NOTES)
    local visible = countableIds(session, NOTE, service.linkedRecords(notes, 'id', 'classification'))
    return service.parentsOf(notes, 'parentId', 'id', visible)
end

--- Note counts (and the latest note) on each listed record, over the notes
--- this reader may read. Never touches a stub.
local function countNotes(session, rows, column, withLatest)
    local ids = idsOf(rows)
    local notes = repo.notesUnder(column, ids)
    local visible = countableIds(session, NOTE, service.linkedRecords(notes, 'id', 'classification'))
    local counts = service.countLinked(notes, 'parentId', 'id', visible)
    local latest = withLatest and service.latestLinked(notes, 'parentId', 'id', visible, 'createdAt') or {}

    for _, row in ipairs(rows) do
        if row.restricted ~= true then
            row.noteCount = counts[row.id] or 0
            if withLatest then row.lastNoteAt = latest[row.id] end
        end
    end
end

--- Rows affected of 0 on a versioned update means one of two things, and the
--- caller cannot tell them apart from the count alone: the record is gone, or
--- somebody else saved first. Checking existence separates them so the officer
--- gets "reload and try again" rather than "not found".
local function updateOutcome(affected, exists)
    if affected > 0 then return nil end

    return exists and FredPD.ErrorCode.CONFLICT or FredPD.ErrorCode.NOT_FOUND
end

-- =============================================================================
-- Persons
-- =============================================================================

route.define({
    name = 'intel.person.list',
    perm = 'intel.person.view',
    schema = 'IntelPersonList',
    audit = 'intel.person.listed',
    auditDetail = function(input, result)
        return { count = #result.persons, search = input.search, tag = input.tag }
    end,
    handler = function(session, input)
        local ids
        if input.tag then
            ids = taggedParents(session, input.tag, 'person_id')
            if #ids == 0 then return { persons = {} } end
        end

        local persons = access().filterSearch(session, PERSON, repo.listPersons(session.agencyId, {
            search = service.searchTerm(input.search),
            status = input.status,
            ids = ids,
            limit = input.limit,
        }))
        countNotes(session, persons, 'person_id', true)

        return { persons = persons }
    end,
})

route.define({
    name = 'intel.person.get',
    perm = 'intel.person.view',
    schema = 'IntelId',
    audit = 'intel.person.read',
    subjectType = 'intel_person',
    handler = function(session, input)
        local person, refusal = readable(session, PERSON, repo.getPerson(session.agencyId, input.id))
        if not person then return refusal end

        -- Resolved for display, once, here -- the same reason `ordningsbot.get`
        -- attaches the tariff a citation cites rather than leaving the NUI to
        -- re-fetch a bare id. `readPerson` re-checks this session's clearance
        -- on every read: a master link to a record since sealed or moved out
        -- of reach shows as unresolved rather than a name nobody may see.
        local masterPerson
        if person.masterPersonId then
            local master = FredPD.Repo.persons.readPerson(session, person.masterPersonId)
            if master then
                masterPerson = {
                    id = master.id,
                    firstName = master.firstName,
                    lastName = master.lastName,
                    personNumber = master.personNumber,
                }
            end
        end

        return {
            person = person,
            masterPerson = masterPerson,
            memberships = onlyReadable(session, ORG, repo.membershipsForPerson(input.id), 'orgId', 'orgClassification'),
            associates = onlyReadable(session, PERSON, repo.associatesForPerson(input.id),
                'personId', 'personClassification'),
            vehicles = repo.vehiclesForPerson(input.id),
            cases = onlyReadable(session, CASE, repo.caseLinksForPerson(input.id), 'caseId', 'caseClassification'),
            evidence = readableEvidence(session, repo.evidenceFor('person', input.id), 'person'),
            notes = readableNotes(session, repo.listNotes(session.agencyId, { personId = input.id })),
        }
    end,
})

route.define({
    name = 'intel.person.create',
    perm = 'intel.person.edit',
    schema = 'IntelPersonCreate',
    writes = true,
    audit = 'intel.person.created',
    subjectType = 'intel_person',
    handler = function(session, input)
        local id = repo.createPerson(session.agencyId, {
            name = service.blankToNull(input.name),
            alias = service.blankToNull(input.alias),
            description = service.blankToNull(input.description),
            status = input.status,
            classification = input.classification,
        }, session.discordId)

        return { id = id }
    end,
})

route.define({
    name = 'intel.person.update',
    perm = 'intel.person.edit',
    schema = 'IntelPersonUpdate',
    writes = true,
    audit = 'intel.person.updated',
    subjectType = 'intel_person',
    handler = function(session, input)
        local current, refusal = mustRead(session, PERSON, input.id)
        if not current then return refusal end

        local affected = repo.updatePerson(session.agencyId, input.id, input.version, {
            name = input.name and service.blankToNull(input.name),
            alias = input.alias and service.blankToNull(input.alias),
            description = input.description and service.blankToNull(input.description),
            status = input.status,
            classification = input.classification,
        })

        local err = updateOutcome(affected, repo.getPerson(session.agencyId, input.id) ~= nil)
        if err then return route.refuse(err) end

        return { id = input.id }
    end,
})

route.define({
    name = 'intel.person.delete',
    perm = 'intel.record.delete',
    schema = 'IntelId',
    writes = true,
    sensitive = true,
    audit = 'intel.person.deleted',
    subjectType = 'intel_person',
    handler = function(session, input)
        local current, refusal = mustRead(session, PERSON, input.id)
        if not current then return refusal end

        if repo.deletePerson(session.agencyId, input.id) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id }
    end,
})

route.define({
    name = 'intel.person.merge',
    perm = 'intel.person.merge',
    schema = 'IntelPersonMerge',
    writes = true,
    -- The most destructive operation in the module: it attributes one record's
    -- intelligence to another and deletes the original. A stale permission
    -- snapshot is not good enough authority for that.
    sensitive = true,
    audit = 'intel.person.merged',
    subjectType = 'intel_person',
    auditDetail = function(input)
        return { keepId = input.keepId, dropId = input.dropId }
    end,
    handler = function(session, input)
        -- Both ends: a merge moves one record's intelligence onto the other,
        -- so neither may be a record this reader could not open.
        local refusal = mustReadAll(session, { { PERSON, input.keepId }, { PERSON, input.dropId } })
        if refusal then return refusal end

        local keep = repo.getPerson(session.agencyId, input.keepId)
        local drop = repo.getPerson(session.agencyId, input.dropId)

        local merged, err = service.mergePlan(keep, drop)
        if not merged then
            return route.refuse(
                err == 'same' and FredPD.ErrorCode.INVALID or FredPD.ErrorCode.NOT_FOUND,
                err == 'same' and { dropId = 'same_as_keep' } or nil
            )
        end

        if not repo.mergePersons(session.agencyId, input.keepId, input.dropId, merged) then
            return route.refuse(FredPD.ErrorCode.INTERNAL)
        end

        return { id = input.keepId }
    end,
})

--- Ties (or, with no `masterPersonId`, clears) this subject to a confirmed
--- person in the master index (spec 10, 0025) -- the bridge `spaning`'s
--- known-associates read (`server/modules/spaning/routes.lua`) crosses to
--- reach an intelligence subject's associates from a lookout naming a
--- master person.
route.define({
    name = 'intel.person.linkMaster',
    perm = 'intel.person.edit',
    schema = 'IntelPersonLinkMaster',
    writes = true,
    audit = 'intel.person.linkedMaster',
    subjectType = 'intel_person',
    auditDetail = function(input) return { masterPersonId = input.masterPersonId } end,
    handler = function(session, input)
        local current, refusal = mustRead(session, PERSON, input.id)
        if not current then return refusal end

        if input.masterPersonId then
            -- `Repo.readPerson` is the persons module's own entry point: it
            -- scopes to the agency, runs the access check and audits a
            -- restricted read (invariant 11) -- the same reuse
            -- `frihet/routes.lua`'s gripande handler relies on, and for the
            -- same reason: an unchecked id would let an analyst confirm the
            -- existence of a person outside their own clearance.
            -- A hidden person is answered as an unknown one and a stubbed one
            -- as restricted -- the persons module's own rule (`refusalCode`).
            local person, visibility = FredPD.Repo.persons.readPerson(session, input.masterPersonId)

            if not person then
                local stub = visibility == 'stub'
                return route.refuse(stub and FredPD.ErrorCode.RESTRICTED or FredPD.ErrorCode.NOT_FOUND,
                    { masterPersonId = stub and 'restricted' or 'unknown' })
            end

            -- `uq_fpd_intel_persons_master` (0025) allows this master person
            -- exactly one linked subject; a second attempt is a conflict, not
            -- a silent takeover of the first analyst's file.
            --
            -- The subject already linked is read like any other: "already
            -- linked" says an intelligence file exists on this person, so it
            -- is said only to a reader who may read that file. Anyone else is
            -- answered as for a person they may not see, and the attempt is
            -- audited as a refused read (invariant 11) -- the constraint still
            -- stops the link, so the refusal never looks like a success.
            local existing = repo.byMasterPersonId(session.agencyId, input.masterPersonId)
            if existing and existing.id ~= input.id then
                local linked, hidden = readable(session, PERSON, existing, { masterPersonId = true })
                if not linked then return hidden end
                return route.refuse(FredPD.ErrorCode.CONFLICT, { masterPersonId = 'already_linked' })
            end
        end

        local affected = repo.setMasterLink(session.agencyId, input.id, input.version, input.masterPersonId)
        local err = updateOutcome(affected, repo.getPerson(session.agencyId, input.id) ~= nil)
        if err then return route.refuse(err) end

        return { id = input.id }
    end,
})

-- =============================================================================
-- Organisations
-- =============================================================================

route.define({
    name = 'intel.org.list',
    perm = 'intel.org.view',
    schema = 'IntelOrgList',
    handler = function(session, input)
        local ids
        if input.tag then
            ids = taggedParents(session, input.tag, 'org_id')
            if #ids == 0 then return { orgs = {} } end
        end

        local orgs = access().filterSearch(session, ORG, repo.listOrgs(session.agencyId, {
            search = service.searchTerm(input.search),
            ids = ids,
            limit = input.limit,
        }))
        countNotes(session, orgs, 'org_id', false)

        -- Members are people: counted only where this reader may read them.
        local members = repo.membersOf(idsOf(orgs))
        local visible = countableIds(session, PERSON, service.linkedRecords(members, 'personId', 'personClassification'))
        local counts = service.countLinked(members, 'orgId', 'personId', visible)
        local confirmed = service.countLinked(members, 'orgId', 'personId', visible,
            function(row) return row.isConfirmed == 1 or row.isConfirmed == true end)
        for _, org in ipairs(orgs) do
            if org.restricted ~= true then
                org.memberCount = counts[org.id] or 0
                org.confirmedCount = confirmed[org.id] or 0
            end
        end

        return { orgs = orgs }
    end,
})

route.define({
    name = 'intel.org.get',
    perm = 'intel.org.view',
    schema = 'IntelId',
    audit = 'intel.org.read',
    subjectType = 'intel_org',
    handler = function(session, input)
        local org, refusal = readable(session, ORG, repo.getOrg(session.agencyId, input.id))
        if not org then return refusal end

        return {
            org = org,
            roster = onlyReadable(session, PERSON, repo.rosterForOrg(input.id), 'personId', 'personClassification'),
            evidence = readableEvidence(session, repo.evidenceFor('org', input.id), 'org'),
            notes = readableNotes(session, repo.listNotes(session.agencyId, { orgId = input.id })),
        }
    end,
})

route.define({
    name = 'intel.org.create',
    perm = 'intel.org.edit',
    schema = 'IntelOrgCreate',
    writes = true,
    audit = 'intel.org.created',
    subjectType = 'intel_org',
    handler = function(session, input)
        local name = service.blankToNull(input.name)
        if not name then return route.refuse(FredPD.ErrorCode.INVALID, { name = 'required' }) end

        return {
            id = repo.createOrg(session.agencyId, {
                name = name,
                type = input.type,
                territory = service.blankToNull(input.territory),
                status = input.status,
                notes = service.blankToNull(input.notes),
                classification = input.classification,
            }, session.discordId),
        }
    end,
})

route.define({
    name = 'intel.org.update',
    perm = 'intel.org.edit',
    schema = 'IntelOrgUpdate',
    writes = true,
    audit = 'intel.org.updated',
    subjectType = 'intel_org',
    handler = function(session, input)
        local current, refusal = mustRead(session, ORG, input.id)
        if not current then return refusal end

        local affected = repo.updateOrg(session.agencyId, input.id, input.version, {
            name = input.name and service.blankToNull(input.name),
            type = input.type,
            territory = input.territory and service.blankToNull(input.territory),
            status = input.status,
            notes = input.notes and service.blankToNull(input.notes),
            classification = input.classification,
        })

        local err = updateOutcome(affected, repo.getOrg(session.agencyId, input.id) ~= nil)
        if err then return route.refuse(err) end

        return { id = input.id }
    end,
})

route.define({
    name = 'intel.org.delete',
    perm = 'intel.record.delete',
    schema = 'IntelId',
    writes = true,
    sensitive = true,
    audit = 'intel.org.deleted',
    subjectType = 'intel_org',
    handler = function(session, input)
        local current, refusal = mustRead(session, ORG, input.id)
        if not current then return refusal end

        -- Notes detach rather than die with the organisation: the foreign key
        -- is ON DELETE SET NULL, not CASCADE.
        -- The intelligence survives; only the profile goes.
        if repo.deleteOrg(session.agencyId, input.id) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id }
    end,
})

-- =============================================================================
-- The intelligence log
-- =============================================================================

route.define({
    name = 'intel.note.list',
    perm = 'intel.report.view',
    schema = 'IntelNoteList',
    audit = 'intel.note.listed',
    auditDetail = function(input, result)
        return { count = #result.notes, tag = input.tag, source = input.source }
    end,
    handler = function(session, input)
        -- Asking for the notes on one subject asks about that subject: it has
        -- to be one this reader may read.
        local refusal = mustReadAll(session, {
            { PERSON, input.personId }, { ORG, input.orgId }, { CASE, input.caseId },
        })
        if refusal then return refusal end

        -- Filtering by where intelligence came from is reading where it came
        -- from: a reader who may not see a protected source may not ask for
        -- the notes that have one.
        if input.source and service.isProtectedSource(input.source) and not canSeeSource(session) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { source = 'not_allowed' })
        end

        local notes = access().filterSearch(session, NOTE, repo.listNotes(session.agencyId, {
                personId = input.personId,
                orgId = input.orgId,
                caseId = input.caseId,
                source = input.source,
                confidence = input.confidence,
                tag = input.tag,
                search = service.searchTerm(input.search),
                limit = input.limit,
            }))

        -- A stub in a filtered list says a note the reader may not open is on
        -- that subject, or carries that tag, or says that word: only the
        -- unfiltered log shows stubs.
        local filtered = input.personId or input.orgId or input.caseId or input.source
            or input.confidence or input.tag or service.searchTerm(input.search)
        if filtered then
            local kept = {}
            for _, note in ipairs(notes) do
                if note.restricted ~= true then kept[#kept + 1] = note end
            end
            notes = kept
        end

        return { notes = redactAll(notes, session) }
    end,
})

route.define({
    name = 'intel.note.create',
    perm = 'intel.report.create',
    schema = 'IntelNoteCreate',
    writes = true,
    limit = { per = 20, window = 60 },
    audit = 'intel.note.created',
    subjectType = 'intel_note',
    auditDetail = function(input)
        return { source = input.source, confidence = input.confidence }
    end,
    handler = function(session, input)
        local err, fields = service.validateNote(input)
        if err then return route.refuse(err, fields) end

        local refusal = mustReadAll(session, {
            { PERSON, input.personId }, { ORG, input.orgId }, { CASE, input.caseId },
        })
        if refusal then return refusal end

        local id = repo.createNote(session.agencyId, {
            personId = input.personId,
            orgId = input.orgId,
            caseId = input.caseId,
            body = service.blankToNull(input.body),
            source = input.source,
            confidence = input.confidence,
            classification = input.classification,
        }, service.normalizeTags(input.tags), session.discordId)

        return { id = id }
    end,
})

route.define({
    name = 'intel.note.update',
    perm = 'intel.report.edit',
    schema = 'IntelNoteUpdate',
    writes = true,
    audit = 'intel.note.updated',
    subjectType = 'intel_note',
    handler = function(session, input)
        local current, refusal = mustRead(session, NOTE, input.id)
        if not current then return refusal end

        local affected = repo.updateNote(session.agencyId, input.id, input.version, {
            body = input.body and service.blankToNull(input.body),
            source = input.source,
            confidence = input.confidence,
            classification = input.classification,
        })

        local err = updateOutcome(affected, repo.getNote(session.agencyId, input.id) ~= nil)
        if err then return route.refuse(err) end

        if input.tags then
            repo.setNoteTags(input.id, service.normalizeTags(input.tags))
        end

        return { id = input.id }
    end,
})

route.define({
    name = 'intel.note.delete',
    perm = 'intel.record.delete',
    schema = 'IntelId',
    writes = true,
    sensitive = true,
    audit = 'intel.note.deleted',
    subjectType = 'intel_note',
    handler = function(session, input)
        local current, refusal = mustRead(session, NOTE, input.id)
        if not current then return refusal end

        if repo.deleteNote(session.agencyId, input.id) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id }
    end,
})

--- How many recent tag uses the tag list counts over.
local TAG_USES <const> = 1000

route.define({
    name = 'intel.tags',
    perm = 'intel.report.view',
    handler = function(session, _input)
        -- Counted over the notes this reader may read: a tag on one they may
        -- not says what it is about.
        local uses = repo.tagUses(session.agencyId, TAG_USES)
        local visible = countableIds(session, NOTE, service.linkedRecords(uses, 'id', 'classification'))
        return { tags = service.tagCounts(uses, visible, 100) }
    end,
})

-- =============================================================================
-- Vehicles
-- =============================================================================

route.define({
    name = 'intel.vehicle.create',
    perm = 'intel.person.edit',
    schema = 'IntelVehicleCreate',
    writes = true,
    audit = 'intel.vehicle.created',
    subjectType = 'intel_vehicle',
    handler = function(session, input)
        local refusal = mustReadAll(session, { { PERSON, input.personId } })
        if refusal then return refusal end

        return {
            id = repo.createVehicle(session.agencyId, {
                personId = input.personId,
                -- Upper-cased and stripped of spaces, so `abc 123` and `ABC123`
                -- are the same plate when somebody searches for one.
                plate = service.normalizePlate(input.plate),
                model = service.blankToNull(input.model),
                color = service.blankToNull(input.color),
                notes = service.blankToNull(input.notes),
            }, session.discordId),
        }
    end,
})

route.define({
    name = 'intel.vehicle.delete',
    perm = 'intel.person.edit',
    schema = 'IntelId',
    writes = true,
    audit = 'intel.vehicle.deleted',
    subjectType = 'intel_vehicle',
    handler = function(session, input)
        local vehicle = repo.vehicleById(session.agencyId, input.id)
        if not vehicle then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end
        local refusal = mustReadAll(session, { { PERSON, vehicle.personId } })
        if refusal then return refusal end

        if repo.deleteVehicle(session.agencyId, input.id) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id }
    end,
})

-- =============================================================================
-- The link diagram (PD-Span's /board, spec 10.6)
-- =============================================================================

--- A board scoped to everything, one case or one organisation. Every node
--- goes through the same access filter a search does, and a node this reader
--- would only see as a stub is left off entirely: a stub on a diagram, with
--- its edges, would say who it is connected to (4.5).
--- How many pages the everyone board reads, at most, to find a full board
--- of people this reader may see. Past that it says "cut", which is also
--- what a genuinely large register says -- the two are not told apart.
local BOARD_PAGES <const> = 4

route.define({
    name = 'intel.board',
    perm = 'intel.person.view',
    schema = 'IntelBoard',
    limit = { per = 20, window = 60 },
    audit = 'intel.board.read',
    auditDetail = function(input, result)
        return { scope = input.scope, id = input.id, persons = #result.persons, orgs = #result.orgs }
    end,
    handler = function(session, input)
        local perms = FredPD.Core.perms
        local cap = service.BOARD_PERSON_CAP
        local ORG_CAP <const> = 200

        local function visible(recordType, rows)
            local out = {}
            for _, row in ipairs(access().filterSearch(session, recordType, rows)) do
                if row.restricted ~= true then out[#out + 1] = row end
            end
            return out
        end

        --- Up to `limit` + 1 visible rows, a page at a time.
        local function fill(recordType, page, limit)
            local out, offset = {}, 0
            for _ = 1, BOARD_PAGES do
                local rows = page(session.agencyId, limit + 1, offset)
                for _, row in ipairs(visible(recordType, rows)) do out[#out + 1] = row end
                if #out > limit or #rows < limit + 1 then return out, #out > limit end
                offset = offset + #rows
            end
            return out, true
        end

        local canOrgs = perms.satisfies(session.permissions, 'intel.org.view')
        local persons, truncated
        local orgs = {}

        if input.scope == 'case' then
            -- A case's board is the case's links: the case permission, as
            -- `intel.case.get` asks, and the case itself readable.
            if not input.id or not perms.satisfies(session.permissions, 'intel.case.view') then
                return route.refuse(FredPD.ErrorCode.NOT_FOUND)
            end
            local record = repo.getCase(session.agencyId, input.id)
            if not record or not access().read(session, CASE, record) then
                return route.refuse(FredPD.ErrorCode.NOT_FOUND)
            end

            local personIds, orgIds = {}, {}
            for _, link in ipairs(repo.caseLinks(input.id)) do
                if link.personId and #personIds <= cap then personIds[#personIds + 1] = link.personId end
                if link.orgId and #orgIds < ORG_CAP then orgIds[#orgIds + 1] = link.orgId end
            end
            truncated = #personIds > cap
            persons = visible('intel_person', repo.boardPersonsById(session.agencyId, personIds))
            orgs = canOrgs and visible('intel_org', repo.boardOrgsById(session.agencyId, orgIds)) or {}
        elseif input.scope == 'org' then
            -- The organisation first: one this reader may not see has no
            -- board, and its roster is never read for it.
            if not input.id or not canOrgs then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end
            orgs = visible('intel_org', repo.boardOrgsById(session.agencyId, { input.id }))
            if #orgs == 0 then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

            local personIds = {}
            for _, member in ipairs(repo.rosterForOrg(input.id)) do
                if #personIds > cap then break end
                personIds[#personIds + 1] = member.personId
            end
            truncated = #personIds > cap
            persons = visible('intel_person', repo.boardPersonsById(session.agencyId, personIds))
        else
            persons, truncated = fill('intel_person', repo.boardPersonsPage, cap)
            if canOrgs then orgs = fill('intel_org', repo.boardOrgsPage, ORG_CAP) end
        end

        local personIds, orgIds = {}, {}
        for index = 1, math.min(#persons, cap) do personIds[index] = persons[index].id end
        for index = 1, math.min(#orgs, ORG_CAP) do orgIds[index] = orgs[index].id end
        local memberships, associates = repo.boardEdges(personIds, orgIds)

        local board = service.boardGraph(persons, { table.unpack(orgs, 1, math.min(#orgs, ORG_CAP)) },
            memberships, associates)
        board.truncated = board.truncated or truncated
        return board
    end,
})

-- =============================================================================
-- Cases
-- =============================================================================

route.define({
    name = 'intel.case.list',
    perm = 'intel.case.view',
    schema = 'IntelCaseList',
    handler = function(session, input)
        local cases = access().filterSearch(session, CASE, repo.listCases(session.agencyId, {
            status = input.status,
            search = service.searchTerm(input.search),
            limit = input.limit,
        }))
        countNotes(session, cases, 'case_id', false)

        -- Each link counted only where this reader may read what it names.
        local links = repo.linksOf(idsOf(cases))
        local people = countableIds(session, PERSON, service.linkedRecords(links, 'personId', 'personClassification'))
        local orgs = countableIds(session, ORG, service.linkedRecords(links, 'orgId', 'orgClassification'))
        local personCounts = service.countLinked(links, 'caseId', 'personId', people)
        local orgCounts = service.countLinked(links, 'caseId', 'orgId', orgs)
        for _, record in ipairs(cases) do
            if record.restricted ~= true then
                record.personCount = personCounts[record.id] or 0
                record.orgCount = orgCounts[record.id] or 0
            end
        end

        return { cases = cases }
    end,
})

route.define({
    name = 'intel.case.get',
    perm = 'intel.case.view',
    schema = 'IntelId',
    audit = 'intel.case.read',
    subjectType = 'intel_case',
    handler = function(session, input)
        local record, refusal = readable(session, CASE, repo.getCase(session.agencyId, input.id))
        if not record then return refusal end

        -- Each link is judged by the record it names, person or organisation.
        local links = onlyReadable(session, PERSON, repo.caseLinks(input.id), 'personId', 'personClassification')
        links = onlyReadable(session, ORG, links, 'orgId', 'orgClassification')

        return {
            case = record,
            links = links,
            evidence = readableEvidence(session, repo.evidenceFor('case', input.id), 'case'),
            notes = readableNotes(session, repo.listNotes(session.agencyId, { caseId = input.id })),
        }
    end,
})

route.define({
    name = 'intel.case.create',
    perm = 'intel.case.edit',
    schema = 'IntelCaseCreate',
    writes = true,
    audit = 'intel.case.created',
    subjectType = 'intel_case',
    handler = function(session, input)
        local title = service.blankToNull(input.title)
        if not title then return route.refuse(FredPD.ErrorCode.INVALID, { title = 'required' }) end

        local case = repo.createCase(session.agencyId, {
            title = title,
            description = service.blankToNull(input.description),
            status = input.status,
            classification = input.classification,
        }, session.discordId)

        if not case then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = case.id, number = case.number, case = case }
    end,
})

route.define({
    name = 'intel.case.update',
    perm = 'intel.case.edit',
    schema = 'IntelCaseUpdate',
    writes = true,
    audit = 'intel.case.updated',
    subjectType = 'intel_case',
    handler = function(session, input)
        local current, refusal = mustRead(session, CASE, input.id)
        if not current then return refusal end

        local affected = repo.updateCase(session.agencyId, input.id, input.version, {
            title = input.title and service.blankToNull(input.title),
            description = input.description and service.blankToNull(input.description),
            status = input.status,
            classification = input.classification,
        })

        local err = updateOutcome(affected, repo.getCase(session.agencyId, input.id) ~= nil)
        if err then return route.refuse(err) end

        return { id = input.id }
    end,
})

route.define({
    name = 'intel.case.delete',
    perm = 'intel.record.delete',
    schema = 'IntelId',
    writes = true,
    sensitive = true,
    audit = 'intel.case.deleted',
    subjectType = 'intel_case',
    handler = function(session, input)
        local current, refusal = mustRead(session, CASE, input.id)
        if not current then return refusal end

        if repo.deleteCase(session.agencyId, input.id) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id }
    end,
})

route.define({
    name = 'intel.case.link.add',
    perm = 'intel.case.edit',
    schema = 'IntelCaseLinkAdd',
    writes = true,
    audit = 'intel.case.linked',
    subjectType = 'intel_case',
    handler = function(session, input)
        -- The database enforces exactly one target; refusing here gives the
        -- officer a field error instead of an internal one.
        local targets = (input.personId and 1 or 0) + (input.orgId and 1 or 0)
        if targets ~= 1 then
            return route.refuse(FredPD.ErrorCode.INVALID, { target = 'exactly_one' })
        end

        local refusal = mustReadAll(session, {
            { CASE, input.caseId }, { PERSON, input.personId }, { ORG, input.orgId },
        })
        if refusal then return refusal end

        return { id = repo.addCaseLink(input, session.discordId) }
    end,
})

route.define({
    name = 'intel.case.link.remove',
    perm = 'intel.case.edit',
    schema = 'IntelId',
    writes = true,
    audit = 'intel.case.unlinked',
    subjectType = 'intel_case',
    handler = function(session, input)
        local link = repo.caseLinkById(session.agencyId, input.id)
        if not link then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end
        local refusal = mustReadAll(session, {
            { CASE, link.caseId }, { PERSON, link.personId }, { ORG, link.orgId },
        })
        if refusal then return refusal end

        if repo.removeCaseLink(input.id) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id }
    end,
})

-- =============================================================================
-- Memberships and associates
-- =============================================================================

route.define({
    name = 'intel.membership.set',
    perm = 'intel.org.edit',
    schema = 'IntelMembershipSet',
    writes = true,
    audit = 'intel.membership.set',
    subjectType = 'intel_person',
    handler = function(session, input)
        local refusal = mustReadAll(session, { { PERSON, input.personId }, { ORG, input.orgId } })
        if refusal then return refusal end

        repo.setMembership({
            personId = input.personId,
            orgId = input.orgId,
            role = service.blankToNull(input.role),
            isConfirmed = input.isConfirmed,
        }, session.discordId)

        return { personId = input.personId, orgId = input.orgId }
    end,
})

route.define({
    name = 'intel.membership.remove',
    perm = 'intel.org.edit',
    schema = 'IntelMembershipRemove',
    writes = true,
    audit = 'intel.membership.removed',
    subjectType = 'intel_person',
    handler = function(session, input)
        local refusal = mustReadAll(session, { { PERSON, input.personId }, { ORG, input.orgId } })
        if refusal then return refusal end

        if repo.removeMembership(input.personId, input.orgId) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { personId = input.personId, orgId = input.orgId }
    end,
})

route.define({
    name = 'intel.associate.set',
    perm = 'intel.person.edit',
    schema = 'IntelAssociateSet',
    writes = true,
    audit = 'intel.associate.set',
    subjectType = 'intel_person',
    handler = function(session, input)
        -- One row per pair, in a fixed order, so A-B and B-A cannot both exist
        -- and the link chart never draws one relationship as two edges.
        local low, high, err = service.orderPair(input.personId, input.associateId)
        if not low then
            return route.refuse(FredPD.ErrorCode.INVALID, { associateId = err })
        end

        local refusal = mustReadAll(session, { { PERSON, low }, { PERSON, high } })
        if refusal then return refusal end

        repo.setAssociate(
            low, high, service.blankToNull(input.relationship), input.isConfirmed, session.discordId
        )

        return { personId = low, associateId = high }
    end,
})

route.define({
    name = 'intel.associate.remove',
    perm = 'intel.person.edit',
    schema = 'IntelAssociateRemove',
    writes = true,
    audit = 'intel.associate.removed',
    subjectType = 'intel_person',
    handler = function(session, input)
        local low, high, err = service.orderPair(input.personId, input.associateId)
        if not low then
            return route.refuse(FredPD.ErrorCode.INVALID, { associateId = err })
        end

        local refusal = mustReadAll(session, { { PERSON, low }, { PERSON, high } })
        if refusal then return refusal end

        if repo.removeAssociate(low, high) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { personId = low, associateId = high }
    end,
})

-- =============================================================================
-- Evidence
-- =============================================================================

route.define({
    name = 'intel.evidence.add',
    perm = 'intel.evidence.add',
    schema = 'IntelEvidenceAdd',
    writes = true,
    audit = 'intel.evidence.added',
    subjectType = 'intel_evidence',
    handler = function(session, input)
        -- Uploads need the gateway's media service to serve them behind signed
        -- URLs (invariant 9), which is not built. Links work today; an upload
        -- is refused rather than stored as a path nothing can render.
        if input.storagePath then
            return route.refuse(FredPD.ErrorCode.INVALID, { storagePath = 'uploads_unavailable' })
        end

        local err, fields = service.validateEvidence(input)
        if err then return route.refuse(err, fields) end

        local refusal = mustReadAll(session, {
            { PERSON, input.personId }, { ORG, input.orgId }, { CASE, input.caseId },
        })
        if refusal then return refusal end

        return {
            id = repo.addEvidence(session.agencyId, {
                personId = input.personId,
                orgId = input.orgId,
                caseId = input.caseId,
                url = service.blankToNull(input.url),
                caption = service.blankToNull(input.caption),
            }, session.discordId),
        }
    end,
})

route.define({
    name = 'intel.evidence.delete',
    perm = 'intel.record.delete',
    schema = 'IntelId',
    writes = true,
    audit = 'intel.evidence.deleted',
    subjectType = 'intel_evidence',
    handler = function(session, input)
        local item = repo.evidenceById(session.agencyId, input.id)
        if not item then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end
        local refusal = mustReadAll(session, {
            { PERSON, item.personId }, { ORG, item.orgId }, { CASE, item.caseId },
        })
        if refusal then return refusal end

        if repo.deleteEvidence(session.agencyId, input.id) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id }
    end,
})

-- =============================================================================
-- Global search
-- =============================================================================

--- The record type each kind of search hit is checked as.
local SEARCH_TYPES <const> = {
    person = PERSON, organization = ORG, note = NOTE, ['case'] = CASE, vehicle = PERSON,
}

route.define({
    name = 'intel.search',
    perm = 'intel.person.view',
    schema = 'IntelSearch',
    limit = { per = 30, window = 60 },
    audit = 'intel.searched',
    auditDetail = function(_input, result)
        -- The count, never the term: a search term is itself intelligence, and
        -- an audit log full of them is a second register nobody meant to keep.
        return { results = #result.results }
    end,
    handler = function(session, input)
        local term = service.searchTerm(input.term)
        if not term then return { results = {} } end

        local rows = repo.search(session.agencyId, term, input.perType or 8)

        -- Each kind through its own record type; a vehicle is judged by the
        -- person it is on. Only what this reader may read in full is
        -- returned: a stub in a mixed result list has no kind to draw, and
        -- hiding is always an allowed answer (4.5).
        local visible = {}
        for kind, recordType in pairs(SEARCH_TYPES) do
            local idField = kind == 'vehicle' and 'ownerId' or 'id'
            local ofKind = {}
            for _, row in ipairs(rows) do
                if row.kind == kind then ofKind[#ofKind + 1] = row end
            end
            -- Once per record: two vehicles on one person are one question.
            local records = service.linkedRecords(ofKind, idField, 'classification')
            visible[kind] = #records > 0 and visibleIds(session, recordType, records) or {}
        end

        local results = {}
        for _, row in ipairs(rows) do
            local owner = row.kind == 'vehicle' and row.ownerId or row.id
            if owner == nil or (visible[row.kind] and visible[row.kind][owner]) then
                row.classification, row.ownerId = nil, nil
                results[#results + 1] = row
            end
        end

        return { results = results }
    end,
})

--- For the spaning module (a lookout naming a master person, 7.13): the
--- associates of the intelligence subject tied to that person, as this
--- session may read them -- nothing when the subject itself is one it may
--- not read, and only the associates it may read in full.
FredPD.Modules.intelAssociatesOf = function(session, masterPersonId)
    local subject = repo.byMasterPersonId(session.agencyId, masterPersonId)
    if not subject or not access().read(session, PERSON, subject) then return {} end

    return onlyReadable(session, PERSON, repo.associatesForPerson(subject.id), 'personId', 'personClassification')
end
