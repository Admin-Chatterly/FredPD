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

local route = FredPD.Core.route
local service = FredPD.Modules.intel
local repo = FredPD.Repo.intel

--- May this session see where protected intelligence came from?
local function canSeeSource(session)
    return FredPD.Core.perms.satisfies(session.permissions, 'intel.source.view')
end

--- Applies source redaction across a list of notes.
local function redactAll(notes, session)
    local visible = canSeeSource(session)

    for index = 1, #notes do
        notes[index] = service.redactSource(notes[index], visible)
    end

    return notes
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
        return {
            persons = repo.listPersons(session.agencyId, {
                search = service.searchTerm(input.search),
                status = input.status,
                tag = input.tag,
                limit = input.limit,
            }),
        }
    end,
})

route.define({
    name = 'intel.person.get',
    perm = 'intel.person.view',
    schema = 'IntelId',
    audit = 'intel.person.read',
    subjectType = 'intel_person',
    handler = function(session, input)
        local person = repo.getPerson(session.agencyId, input.id)
        if not person then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

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
            memberships = repo.membershipsForPerson(input.id),
            associates = repo.associatesForPerson(input.id),
            vehicles = repo.vehiclesForPerson(input.id),
            cases = repo.caseLinksForPerson(input.id),
            evidence = repo.evidenceFor('person', input.id),
            notes = redactAll(repo.listNotes(session.agencyId, { personId = input.id }), session),
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
        if input.masterPersonId then
            -- `Repo.readPerson` is the persons module's own entry point: it
            -- scopes to the agency, runs the access check and audits a
            -- restricted read (invariant 11) -- the same reuse
            -- `frihet/routes.lua`'s gripande handler relies on, and for the
            -- same reason: an unchecked id would let an analyst confirm the
            -- existence of a person outside their own clearance.
            local person, visibility = FredPD.Repo.persons.readPerson(session, input.masterPersonId)

            if not person then
                return route.refuse(
                    visibility == 'missing' and FredPD.ErrorCode.NOT_FOUND or FredPD.ErrorCode.RESTRICTED,
                    { masterPersonId = visibility == 'missing' and 'unknown' or 'restricted' })
            end

            -- `uq_fpd_intel_persons_master` (0025) allows this master person
            -- exactly one linked subject; a second attempt is a conflict, not
            -- a silent takeover of the first analyst's file.
            local existing = repo.byMasterPersonId(session.agencyId, input.masterPersonId)
            if existing and existing.id ~= input.id then
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
        return {
            orgs = repo.listOrgs(session.agencyId, {
                search = service.searchTerm(input.search),
                tag = input.tag,
                limit = input.limit,
            }),
        }
    end,
})

route.define({
    name = 'intel.org.get',
    perm = 'intel.org.view',
    schema = 'IntelId',
    audit = 'intel.org.read',
    subjectType = 'intel_org',
    handler = function(session, input)
        local org = repo.getOrg(session.agencyId, input.id)
        if not org then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        return {
            org = org,
            roster = repo.rosterForOrg(input.id),
            evidence = repo.evidenceFor('org', input.id),
            notes = redactAll(repo.listNotes(session.agencyId, { orgId = input.id }), session),
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
        return {
            notes = redactAll(repo.listNotes(session.agencyId, {
                personId = input.personId,
                orgId = input.orgId,
                caseId = input.caseId,
                source = input.source,
                confidence = input.confidence,
                tag = input.tag,
                search = service.searchTerm(input.search),
                limit = input.limit,
            }), session),
        }
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
        if repo.deleteNote(session.agencyId, input.id) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id }
    end,
})

route.define({
    name = 'intel.tags',
    perm = 'intel.report.view',
    handler = function(session, _input)
        return { tags = repo.tags(session.agencyId) }
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
        if repo.deleteVehicle(session.agencyId, input.id) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id }
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
        return {
            cases = repo.listCases(session.agencyId, {
                status = input.status,
                search = service.searchTerm(input.search),
                limit = input.limit,
            }),
        }
    end,
})

route.define({
    name = 'intel.case.get',
    perm = 'intel.case.view',
    schema = 'IntelId',
    audit = 'intel.case.read',
    subjectType = 'intel_case',
    handler = function(session, input)
        local record = repo.getCase(session.agencyId, input.id)
        if not record then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        return {
            case = record,
            links = repo.caseLinks(input.id),
            evidence = repo.evidenceFor('case', input.id),
            notes = redactAll(repo.listNotes(session.agencyId, { caseId = input.id }), session),
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

        if not repo.getCase(session.agencyId, input.caseId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

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
    handler = function(_session, input)
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
        if not repo.getPerson(session.agencyId, input.personId)
            or not repo.getOrg(session.agencyId, input.orgId)
        then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

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
    handler = function(_session, input)
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

        if not repo.getPerson(session.agencyId, low) or not repo.getPerson(session.agencyId, high) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

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
    handler = function(_session, input)
        local low, high, err = service.orderPair(input.personId, input.associateId)
        if not low then
            return route.refuse(FredPD.ErrorCode.INVALID, { associateId = err })
        end

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
        if repo.deleteEvidence(session.agencyId, input.id) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id }
    end,
})

-- =============================================================================
-- Global search
-- =============================================================================

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

        return { results = repo.search(session.agencyId, term, input.perType or 8) }
    end,
})
