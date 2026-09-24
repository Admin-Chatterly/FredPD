--- Master name index routes (spec 7.3, 7.2).
---
--- Four routes -- search, read, edit, caution -- and two kinds of access
--- control layered on each other. Keeping them apart is the whole design of
--- this file.
---
--- **Record-level access** (4.5) decides whether a person may leave the
--- database at all. It is applied in `repo.lua`, inside every read, by the
--- access module: classification against clearance, every compartment on the
--- record, grants, seals. A refused record is either a three-field stub or
--- absent entirely, and the search applies it to the *result set*, not to the
--- detail view -- a list that names a restricted person and then refuses to
--- open them has already said the thing the compartment exists to keep quiet
--- (invariant 4).
---
--- **Field-level access** (4.5, "field-level redaction") decides which parts of
--- a record a reader who may read it sees. It is applied here, because it is a
--- question about the session's permissions rather than about the row. Two
--- fields are gated in this module:
---
---   * `fields.mental_health.view` -- a mental-health caution. A reader without
---     it sees the person, and does not see that the caution is there. Not the
---     caution with its detail blanked: a flag on a person's file reading
---     "mental health -- detail withheld" discloses exactly the fact the
---     permission exists to protect, and an officer who cannot be told the
---     detail cannot act on it either way. The database makes this enforceable
---     rather than conventional: `ck_fpd_person_cautions_field` refuses a
---     mental-health caution that does not carry the field key.
---   * `fields.victim_address.view` -- a person's address. The address stays on
---     the record; the reader without the permission is simply not sent it.
---
--- Both are applied on every path that returns the field, search results
--- included, because a redaction the list forgets is a redaction that does not
--- exist.
---
--- **Nothing user-facing is built here** (invariant 6). A refusal is an error
--- code and a stub is a `contact` key; the NUI renders both from its locale
--- files.

local route = FredPD.Core.route
local repo = FredPD.Repo.persons
local accessRepo = FredPD.Repo.access
local access = FredPD.Modules.access

--- The record type these rows are known by in the access tables.
local RECORD_TYPE <const> = 'person'

--- Which `fields.<key>.view` permission gates a caution of each kind (4.5).
---
--- Derived on the server from the kind, never taken from input: a client that
--- could choose the field key could write a mental-health caution declaring
--- itself gated on nothing, and publish a person's diagnosis to the whole
--- department.
local CAUTION_FIELD_KEY <const> = {
    mental_health = 'mental_health',
}

-- =============================================================================
-- Helpers
-- =============================================================================

--- nil for anything blank, so an empty box in the interface is "not given"
--- rather than an empty string in a WHERE clause.
local function blank(value)
    if type(value) ~= 'string' then return nil end

    local trimmed = value:match('^%s*(.-)%s*$')

    return trimmed ~= '' and trimmed or nil
end

--- Does this session hold `fields.<key>.view` (Appendix B)?
local function canSeeField(session, key)
    return FredPD.Core.perms.satisfies(session.permissions, ('fields.%s.view'):format(key))
end

--- Is this reader cleared for records at this classification?
---
--- Used on the write paths. Clearance decides what may be *read*, and a record
--- may not be written into a level its author could not then read: that is
--- either an accident that loses the record or a way to file something where
--- the person filing it cannot be asked about it.
--- Delegates to the shared rule so the registers and this module cannot drift
--- apart on what "may classify" means. The one difference is the nil case:
--- `canClassify` treats an absent level as "leave it alone" and allows it,
--- while every caller here has already decided a level and must not be handed
--- a pass for nil.
local function clearedFor(reader, level)
    return level ~= nil and access.canClassify(reader, level)
end

--- Removes the address from a person row unless the reader may see it.
---
--- The row is a copy the access module built, so this does not touch anything
--- that outlives the request. `addressRestricted` is a flag rather than a
--- sentence: the interface renders it from a locale key (invariant 6), and it
--- exists so the field reads as withheld rather than as empty -- "no address on
--- file" and "you may not see the address" are different facts about a person.
local function redactAddress(session, person)
    if type(person) ~= 'table' or person.restricted then return person end

    if person.address ~= nil and not canSeeField(session, 'victim_address') then
        person.address = nil
        person.addressRestricted = true
    end

    return person
end

--- The cautions this session may know about (7.3).
---
--- Two tests, and a caution has to pass both:
---
---   1. **The field gate.** A caution carrying a `field_key` is withheld in
---      full from a reader without `fields.<key>.view`. Withheld, not blanked --
---      see the header.
---   2. **The classification.** A caution carries its own classification, so an
---      officer-safety flag can be open while the intelligence-led one beside it
---      is confidential. The pure access service answers that with the same
---      clearance comparison it applies to a record; the caution has no
---      compartments, grants or seal of its own, so this is a classification
---      test and nothing more.
---
--- @param session table
--- @param reader table from `accessRepo.reader`
--- @param list table cautions as the repo read them
--- @return table the visible ones
local function visibleCautions(session, reader, list)
    local out = {}

    for index = 1, #list do
        local caution = list[index]
        local fieldOk = caution.fieldKey == nil or canSeeField(session, caution.fieldKey)

        if fieldOk and access.canRead(reader, caution) then
            out[#out + 1] = caution
        end
    end

    return out
end

--- The same classification test for photographs, which carry one each: a
--- mugshot is routine, a surveillance photograph on the same file may not be.
local function visiblePhotos(reader, list)
    local out = {}

    for index = 1, #list do
        if access.canRead(reader, list[index]) then out[#out + 1] = list[index] end
    end

    return out
end

--- What a list row says about a person's cautions.
---
--- The kind and the expiry, never the detail. A result list is read at a
--- roadside and the detail of a caution is a paragraph; more to the point, the
--- detail is the part that is field-gated, and a list is the easiest place to
--- leak one by accident.
local function cautionFlags(cautions)
    local flags = {}

    for index = 1, #cautions do
        flags[index] = {
            kind = cautions[index].kind,
            expiresAt = cautions[index].expiresAt,
        }
    end

    return flags
end

--- Rows affected of 0 on a versioned update means the record is gone or
--- somebody else saved first, and the count alone cannot tell them apart.
local function updateOutcome(affected, exists)
    if affected > 0 then return nil end

    return exists and FredPD.ErrorCode.CONFLICT or FredPD.ErrorCode.NOT_FOUND
end

--- How a refused read is reported.
---
--- `stub` means the reader is allowed to know the record exists, so they are
--- told it is restricted. `hidden` means they are not, so the record is
--- answered exactly as a record that does not exist -- same code, same shape,
--- same timing as far as anything a client can see.
local function refusalCode(visibility)
    return visibility == 'stub' and FredPD.ErrorCode.RESTRICTED or FredPD.ErrorCode.NOT_FOUND
end

-- =============================================================================
-- Search (7.2, 7.3)
-- =============================================================================

route.define({
    name = 'person.search',
    perm = 'rms.person.view',
    schema = 'PersonSearch',
    -- A search is cheap for the officer and expensive for the database, and a
    -- scripted client running one in a loop is how a records system becomes a
    -- copy of itself in somebody's spreadsheet (spec 11.1).
    limit = { per = 30, window = 60 },
    audit = 'person.searched',
    auditDetail = function(_input, result)
        -- The count, never the term. The term belongs in `fpd_query_log`, which
        -- exists to hold it and is swept on a retention policy (13.3); an audit
        -- log full of search terms is a second register nobody meant to keep.
        return {
            results = #result.persons,
            restrictedWithheld = result.restrictedWithheld,
        }
    end,
    handler = function(session, input)
        -- An empty box is a deliberate request to browse the roster rather
        -- than search it (7.2) -- `terms = nil` says so to `repo.searchPersons`,
        -- which reads it as "everyone" rather than as a fragment nothing can
        -- match. A term that is not blank but is still too short to search
        -- stays a refusal: one stray character is a mistake, not a browse.
        local terms
        if blank(input.term) ~= nil then
            terms = repo.parseTerm(input.term)
            if not terms then
                return route.refuse(FredPD.ErrorCode.INVALID, { term = 'too_short' })
            end
        end

        -- `DATE` column, so the term has to be a date. The schema layer has no
        -- pattern type, so the shape is checked here rather than handed to
        -- MariaDB to reject with a warning and a silent zero date.
        local dateOfBirth = blank(input.dateOfBirth)
        if dateOfBirth and not dateOfBirth:match('^%d%d%d%d%-%d%d%-%d%d$') then
            return route.refuse(FredPD.ErrorCode.INVALID, { dateOfBirth = 'format' })
        end

        -- 7.2: a query that reaches restricted data carries a reason or a case
        -- number. Without one the restricted rows are withheld from a reader
        -- who is otherwise cleared for them, and the flag in the answer is what
        -- asks for the reason.
        local reason = blank(input.reason)
        local caseNumber = blank(input.caseNumber)

        local found = repo.searchPersons(session, {
            terms = terms,
            dateOfBirth = dateOfBirth,
            limit = input.limit,
            allowRestricted = reason ~= nil or caseNumber ~= nil,
        })

        -- Cautions are loaded for the rows that survived access control, in one
        -- query, and never for a stub: a stub has no id, and loading flags for a
        -- record the reader may not see would put the reason it is flagged on
        -- the screen of somebody refused the record itself.
        local ids = {}
        for index = 1, #found.persons do
            local person = found.persons[index]
            if person.id then ids[#ids + 1] = person.id end
        end

        local reader = accessRepo.reader(session)
        local cautions = repo.liveCautions(session.agencyId, ids)
        local hits = 0

        for index = 1, #found.persons do
            local person = found.persons[index]

            if person.id then
                local visible = visibleCautions(session, reader, cautions[person.id] or {})

                person.cautions = cautionFlags(visible)
                if #visible > 0 then hits = hits + 1 end

                redactAddress(session, person)
            end
        end

        -- 7.2: every query is logged, whoever ran it and whatever it found --
        -- including a search that found nothing, which is as interesting to a
        -- misuse investigation as one that did.
        repo.logQuery(session, {
            queryType = 'person',
            -- `''` for a browse: there is no term to log, and `fpd_query_log.term`
            -- is `NOT NULL` (0005:892).
            term = terms and terms.full or '',
            restricted = found.restrictedIncluded,
            reason = reason,
            caseNumber = caseNumber,
            resultCount = #found.persons,
            hitCount = hits,
        })

        return {
            persons = found.persons,
            -- True only when the reader is cleared for the rows being held
            -- back. A reader who is not cleared for them never learns they
            -- exist: those rows were already gone before this function saw the
            -- list (invariant 4).
            restrictedWithheld = found.restrictedWithheld,
            -- Citizens the framework knows who have no record here yet
            -- (population register): a search is not a browse of them.
            population = terms and FredPD.Modules.populationSearch.characters(session, terms.full) or {},
        }
    end,
})

-- =============================================================================
-- One person (7.3)
-- =============================================================================

route.define({
    name = 'person.get',
    perm = 'rms.person.view',
    schema = 'PersonGet',
    audit = 'person.read',
    subjectType = RECORD_TYPE,
    auditDetail = function(_input, result)
        return { restricted = result.restricted == true }
    end,
    handler = function(session, input)
        local person, visibility, raw = repo.readPerson(session, input.id)

        if not person then
            if visibility ~= 'stub' then
                return route.refuse(refusalCode(visibility))
            end

            -- 4.5: "Restricted record -- contact <unit>". Three fields, built
            -- from nothing: no name, no number, no date, no classification.
            -- `contact` is a key the NUI renders (invariant 6).
            local reader = accessRepo.reader(session)

            return {
                id = input.id,
                restricted = true,
                person = access.stub(raw, access.missingCompartments(reader, raw)),
            }
        end

        local reader = accessRepo.reader(session)
        local cautions = repo.liveCautions(session.agencyId, { person.id })[person.id] or {}

        -- A photograph the reader may read gets a link signed for a few
        -- minutes (ADR-019); the ref alone is worth nothing to anybody.
        local media = FredPD.Modules.mediaApi
        local photos = visiblePhotos(reader, repo.photos(session.agencyId, person.id))
        for _, photo in ipairs(photos) do
            if media then photo.url, photo.thumbnailUrl = media.links(photo.mediaRef) end
            photo.mediaRef, photo.createdBy = nil, nil
        end

        return {
            id = person.id,
            person = redactAddress(session, person),
            aliases = repo.aliases(session.agencyId, person.id),
            descriptors = repo.descriptors(session.agencyId, person.id),
            photos = photos,
            photoCapture = media ~= nil and media.canCapture(session) or false,
            cautions = visibleCautions(session, reader, cautions),
            biometrics = repo.biometrics(session.agencyId, person.id),
            -- Read under their own record types, so a person an officer may
            -- read never carries a restricted vehicle or firearm out with them.
            vehicles = repo.linkedVehicles(session, person.id),
            firearms = repo.linkedFirearms(session, person.id),
            -- Licence points from citations (0036), for a reader of citations.
            licence = FredPD.Modules.ordningsbotLicence and FredPD.Modules.ordningsbotLicence.standingFor(session, person.id)
                or nil,
        }
    end,
})

-- =============================================================================
-- Editing (7.3)
-- =============================================================================

route.define({
    name = 'person.create',
    perm = 'rms.person.edit',
    schema = 'PersonCreate',
    writes = true,
    audit = 'person.created',
    subjectType = RECORD_TYPE,
    handler = function(session, input)
        -- `Repo.createPerson` has sat unused since 7.3 was written: identity
        -- was meant to come from the framework, from whichever path first
        -- meets a person (booking, an arrest), not from an officer typing a
        -- new file into existence. This is the first such path -- an
        -- identifier picked from `esx.character.search`, or a name given by
        -- hand for someone not yet identified -- and it keeps that rule: a
        -- call naming neither is refused rather than writing an empty row
        -- nothing distinguishes from any other.
        local identifier = blank(input.identifier)
        local firstName = blank(input.firstName)
        local lastName = blank(input.lastName)

        if not identifier and not firstName and not lastName then
            return route.refuse(FredPD.ErrorCode.INVALID, { lastName = 'required' })
        end

        -- Same shape check `person.search` applies, for the same reason: no
        -- pattern type at the schema layer, so a malformed date is caught
        -- here rather than handed to MariaDB to reject with a warning and a
        -- silent zero date.
        local dateOfBirth = blank(input.dateOfBirth)
        if dateOfBirth and not dateOfBirth:match('^%d%d%d%d%-%d%d%-%d%d$') then
            return route.refuse(FredPD.ErrorCode.INVALID, { dateOfBirth = 'format' })
        end

        local id = repo.createPerson(session.agencyId, {
            identifier = identifier,
            firstName = firstName,
            middleName = blank(input.middleName),
            lastName = lastName,
            dateOfBirth = dateOfBirth,
            sex = input.sex,
            phone = blank(input.phone),
            address = blank(input.address),
            classification = input.classification,
        }, session.discordId)

        if not id then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = id }
    end,
})

route.define({
    name = 'person.update',
    perm = 'rms.person.edit',
    schema = 'PersonUpdate',
    writes = true,
    audit = 'person.updated',
    subjectType = RECORD_TYPE,
    auditDetail = function(input)
        -- Which fields were touched, never what they were set to: the audit log
        -- records that a person's address changed, and the record records what
        -- it changed to (invariant 11).
        local changed = {}

        for _, name in ipairs({
            'firstName', 'middleName', 'lastName', 'dateOfBirth', 'sex',
            'phone', 'address', 'classification', 'deceased', 'missing',
        }) do
            if input[name] ~= nil then changed[#changed + 1] = name end
        end

        return { fields = changed }
    end,
    handler = function(session, input)
        -- Read first, through the access module, and for two reasons: an
        -- officer must not edit a record they may not read, and the read is what
        -- writes the audit entry for having opened a restricted one.
        local person, visibility = repo.readPerson(session, input.id)
        if not person then
            return route.refuse(refusalCode(visibility))
        end

        local reader = accessRepo.reader(session)

        -- The address is field-gated on the way in as well as on the way out. A
        -- reader who is not shown the address must not be able to overwrite it:
        -- their form was rendered without it, so anything arriving in that field
        -- is either a stale client or a deliberate one.
        if input.address ~= nil and not canSeeField(session, 'victim_address') then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { address = 'field_forbidden' })
        end

        if input.classification ~= nil and not clearedFor(reader, input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'clearance' })
        end

        local fields = {
            firstName = input.firstName,
            middleName = input.middleName,
            lastName = input.lastName,
            dateOfBirth = input.dateOfBirth,
            sex = input.sex,
            phone = input.phone,
            address = input.address,
            classification = input.classification,
            deceased = input.deceased,
            missing = input.missing,
        }

        if next(fields) == nil then
            return route.refuse(FredPD.ErrorCode.INVALID, { _input = 'nothing_to_change' })
        end

        if fields.dateOfBirth ~= nil and fields.dateOfBirth ~= ''
            and not fields.dateOfBirth:match('^%d%d%d%d%-%d%d%-%d%d$')
        then
            return route.refuse(FredPD.ErrorCode.INVALID, { dateOfBirth = 'format' })
        end

        local affected = repo.updatePerson(
            session.agencyId, input.id, input.version, fields, session.discordId
        )

        -- The record was readable a moment ago, so 0 rows means the version
        -- moved under this edit: somebody else saved first.
        local err = updateOutcome(affected, true)
        if err then return route.refuse(err) end

        return { id = input.id }
    end,
})

-- =============================================================================
-- Cautions and flags (7.3)
-- =============================================================================

route.define({
    name = 'person.caution.set',
    perm = 'rms.person.caution.edit',
    schema = 'PersonCautionSet',
    writes = true,
    -- A caution is what an officer is shown before they get out of the car. A
    -- permission snapshot that may be an hour stale is not the authority to add
    -- one or to take one away (spec 4.2).
    sensitive = true,
    audit = 'person.caution.set',
    subjectType = RECORD_TYPE,
    auditDetail = function(input)
        -- The kind and the shape of the change. Never `detail`: on a
        -- mental-health caution that is the one string in this module that the
        -- field permission exists to keep off most screens, and an audit entry
        -- is read by everyone with `admin.audit.view`.
        return {
            kind = input.kind,
            cancel = input.cancel == true,
            expiresInDays = input.expiresInDays,
        }
    end,
    handler = function(session, input)
        if input.cancel then
            if not input.cautionId then
                return route.refuse(FredPD.ErrorCode.INVALID, { cautionId = 'required' })
            end

            local caution = repo.getCaution(session.agencyId, input.cautionId)
            if not caution then
                return route.refuse(FredPD.ErrorCode.NOT_FOUND)
            end

            -- A caution the reader may not be told about is a caution they may
            -- not cancel, and the refusal is `not_found` rather than
            -- `forbidden`: "you are not allowed to remove this" would tell them
            -- it is there, which is the whole of what the field gate withholds.
            if caution.fieldKey and not canSeeField(session, caution.fieldKey) then
                return route.refuse(FredPD.ErrorCode.NOT_FOUND)
            end

            local person, visibility = repo.readPerson(session, caution.personId)
            if not person then
                return route.refuse(refusalCode(visibility))
            end

            local affected = repo.cancelCaution(session.agencyId, input.cautionId, session.discordId)
            if affected == 0 then
                return route.refuse(FredPD.ErrorCode.CONFLICT)
            end

            return { id = input.cautionId, personId = caution.personId }
        end

        if not input.personId or not input.kind then
            local missing = {}
            if not input.personId then missing.personId = 'required' end
            if not input.kind then missing.kind = 'required' end

            return route.refuse(FredPD.ErrorCode.INVALID, missing)
        end

        local person, visibility = repo.readPerson(session, input.personId)
        if not person then
            return route.refuse(refusalCode(visibility))
        end

        -- Writing a field-gated caution needs the permission that reads it.
        -- Otherwise an officer could file a mental-health flag they would not
        -- then be shown, could not correct, and could not answer for.
        local fieldKey = CAUTION_FIELD_KEY[input.kind]
        if fieldKey and not canSeeField(session, fieldKey) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { kind = 'field_forbidden' })
        end

        local reader = accessRepo.reader(session)
        local classification = input.classification or 'internal'

        if not clearedFor(reader, classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'clearance' })
        end

        local id = repo.addCaution(session.agencyId, input.personId, {
            kind = input.kind,
            detail = input.detail,
            fieldKey = fieldKey,
            sourceCase = input.sourceCase,
            classification = classification,
            -- Days, turned into a moment by the database (invariant 1). 0 is a
            -- caution that does not expire, which is what "armed" usually is.
            expiresInDays = input.expiresInDays or 0,
        }, session.discordId)

        return { id = id, personId = input.personId }
    end,
})
