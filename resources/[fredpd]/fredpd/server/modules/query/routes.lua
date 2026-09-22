--- The unified query and hot-file hits (spec 7.2).
---
--- Three routes: run a query, confirm a hit it raised, and read the query log
--- back. They obey the rules the registers obey, and two of their own.
---
--- **Access is checked on the server, for every read, search results included**
--- (invariant 4). A record this reader may not know about never appears in a
--- ranked list -- not as an id, not as a plate, not as a gap between two rows
--- that scored either side of it. `access.filterSearch` does that, per register,
--- before anything is ranked, and nothing in this file filters rows itself. A
--- reader must not learn that a record exists by seeing it ranked and then
--- withheld, which is why the filtering happens before the ranking rather than
--- after it.
---
--- **Every query is logged** (7.2), including the one that found nothing and
--- the one that was refused for want of a reason. `fpd_query_log` answers "who
--- has been looking up their ex-partner", which is the most common real misuse
--- of a police system, and a query that matched nothing is part of that answer.
---
--- **A hit comes back unconfirmed.** Finding a stolen-vehicle flag is a lead;
--- confirming it is a second, deliberate act that `query.hit.confirm` records
--- against the query that raised it. An officer who acts on an unconfirmed hit
--- has done something a department may ask about afterwards, and the log can
--- tell the two apart because the confirmation is a row and its absence is
--- visible (`query.log` returns both counts).
---
--- **A query into restricted data needs a reason or a case number** (7.2). The
--- rule is the registers' rule and is applied the registers' way: on what is
--- about to be disclosed, after filtering and after trimming to the page,
--- because a record the reader cannot open is not a disclosure and a stub is not
--- one either. The refusal happens before anything is returned, so an officer
--- with no reason learns nothing at all -- not even that the registers hold
--- something worth a reason.

local route = FredPD.Core.route
local service = FredPD.Modules.query
local repo = FredPD.Repo.query

--- The registers' own service, for the VIN test, the hot-file allowlists and
--- the two paging helpers. A module reaches another module through its
--- `service.lua` and never its `repo.lua`: the SQL below is this module's own.
local registry = FredPD.Modules.registry

--- Record-level access (4.5). `FredPD.Repo.access` is the half that loads
--- compartments, grants and seals and writes the audit entry;
--- `FredPD.Modules.access` is the pure half, used here for decisions about a
--- child row that is already loaded.
local access = FredPD.Repo.access
local accessRules = FredPD.Modules.access

--- A flag and a caution are *not* run through `filterSearchResults` the way a
--- record is. A record the reader may not open can still come back as a stub,
--- because 4.5 wants them told the file exists; a hot-file hit they may not
--- know about is simply not raised. A red banner reading "restricted" is worse
--- than no banner: it says there is something on this person and refuses to say
--- what, which is an accusation an officer cannot check and the subject cannot
--- answer. Both are dropped by `visibleFlags` and `visibleCautions` below.

-- =============================================================================
-- Helpers
-- =============================================================================

--- A row that survived access filtering with its contents, rather than as a
--- stub. A stub has no id; that is the whole of its design.
local function opened(row)
    return type(row) == 'table' and row.id ~= nil
end

--- Marks rows with what kind of record they are, before access filtering.
---
--- It has to be on the row before filtering, because the stub is built from the
--- row and never from anything after it: it is what lets the interface render
--- "Restricted record" with the right label instead of an unlabelled gap (4.5).
local function tagRecordType(rows, recordType)
    for index = 1, #rows do rows[index].recordType = recordType end

    return rows
end

--- Does this session hold `fields.<key>.view` (Appendix B, 4.5)?
local function canSeeField(session, key)
    return FredPD.Core.perms.satisfies(session.permissions, ('fields.%s.view'):format(key))
end

--- Removes the address from a person row unless the reader may see it.
---
--- The same rule `person.search` applies, applied here too because a redaction
--- one list forgets is a redaction that does not exist. `addressRestricted` is
--- a flag rather than a sentence (invariant 6): "no address on file" and "you
--- may not see the address" are different facts about a person.
---
--- An *address query* is deliberately still allowed without the field
--- permission -- it is `query.address.run` that decides who may ask "who lives
--- here", and 7.2 gives that its own key -- but the address does not come back
--- in the answer, because the officer already typed the only part of it they
--- are entitled to.
local function redactAddress(session, person)
    if type(person) ~= 'table' or person.restricted then return person end

    if person.address ~= nil and not canSeeField(session, 'victim_address') then
        person.address = nil
        person.addressRestricted = true
    end

    return person
end

--- The cautions this session may know about (7.3, 4.5).
---
--- Two tests, and a caution has to pass both: the `fields.<key>.view` gate,
--- which withholds a field-gated caution in full rather than blanking its
--- detail, and the caution's own classification, because an officer-safety flag
--- can be open while the intelligence-led one beside it is confidential. A
--- caution that fails either never reaches the banner.
local function visibleCautions(session, reader, list)
    local out = {}

    for index = 1, #list do
        local caution = list[index]
        local fieldOk = caution.fieldKey == nil or canSeeField(session, caution.fieldKey)

        if fieldOk and accessRules.canRead(reader, caution) then
            out[#out + 1] = caution
        end
    end

    return out
end

--- The flags this session may know about: the classification test alone, since
--- a flag has no field gate of its own.
local function visibleFlags(reader, list)
    local out = {}

    for index = 1, #list do
        if accessRules.canRead(reader, list[index]) then out[#out + 1] = list[index] end
    end

    return out
end

--- Refuses a result that would open restricted data with no reason given (7.2).
---
--- `registry.opensRestricted` is asked rather than re-implemented: it is the
--- rule the two registers already apply, and a second copy here would be the
--- same rule until the day one of them changed.
local function reasonSatisfied(rows, reason, caseNumber)
    if reason or caseNumber then return true end

    return not registry.opensRestricted(rows, accessRules.isRestricted)
end

--- Writes the query log row (7.2) and returns its id.
---
--- `restricted` is true only when the query actually opened a restricted record
--- *and* a reason was given; a query refused for want of one is logged with
--- nothing found, because nothing was disclosed. `ck_fpd_query_log_reason`
--- enforces the same pairing in the database.
local function logQuery(session, queryType, term, rows, hits, reason, caseNumber)
    return repo.logQuery(session, {
        queryType = queryType,
        term = term or '',
        restricted = (reason ~= nil or caseNumber ~= nil)
            and registry.opensRestricted(rows, accessRules.isRestricted),
        reason = reason,
        caseNumber = caseNumber,
        resultCount = #rows,
        hitCount = hits,
    })
end

--- Runs one register's rows through access control and scores what survives.
---
--- The score is computed from the row the reader is allowed to have, never from
--- the row the database returned: a stub scores as a stub (`STUB_SCORE`),
--- which is the only honest rank for a row whose contents nobody in this
--- session may read.
local function collect(session, context, recordType, rows, into)
    local visible = access.filterSearch(session, recordType, tagRecordType(rows, recordType))

    for index = 1, #visible do
        local row = visible[index]

        row.kind = recordType
        row.score = service.score(context, row)

        into[#into + 1] = row
    end

    return into
end

--- The ids of the opened rows of one kind, for a batched child query.
local function idsOfKind(rows, kind)
    local ids = {}

    for index = 1, #rows do
        local row = rows[index]
        if row.kind == kind and opened(row) then ids[#ids + 1] = row.id end
    end

    return ids
end

--- A sorted list of the registers a query actually read.
---
--- Returned to the interface so it can say which register was left out, and
--- why: a firearm search that silently did not happen because the officer lacks
--- `query.firearm.run` looks exactly like a firearm register with nothing in it.
local function sortedKeys(set)
    local keys = {}
    for key in pairs(set) do keys[#keys + 1] = key end
    table.sort(keys)

    return keys
end

-- =============================================================================
-- The query (7.2)
-- =============================================================================

route.define({
    name = 'query.run',
    -- The umbrella permission for the unified box. It grants nothing on its
    -- own: which registers are actually read is decided per source below,
    -- against the five `query.<thing>.run` keys 7.2 names, so an officer who
    -- may run a plate and not a person gets the vehicle half and no hint that
    -- the other half exists.
    perm = 'query.run',
    schema = 'QueryRun',
    -- A query is cheap for the officer and expensive for three registers at
    -- once, and a scripted client running one in a loop is how a records system
    -- becomes a copy of itself in somebody's spreadsheet (spec 11.1).
    limit = { per = 30, window = 60 },
    audit = 'query.run',
    auditDetail = function(_input, result)
        -- The type and the counts, never the term. What an officer searched for
        -- is itself information about an investigation; it belongs in
        -- `fpd_query_log`, which exists to hold it and is swept on a retention
        -- policy (13.3), not in an audit log read by everyone with
        -- `admin.audit.view`.
        return {
            type = result and result.type or nil,
            count = result and #result.results or 0,
            hits = result and result.hits or 0,
        }
    end,
    handler = function(session, input)
        -- An explicit type disambiguates what the term cannot say for itself
        -- (7.2). The schema bounds the string; this decides whether it is one
        -- of the six names, `serial` included as 7.2 spells it.
        local explicit
        if input.type ~= nil then
            explicit = service.canonicalType(input.type)

            if not explicit then
                return route.refuse(FredPD.ErrorCode.INVALID, { type = 'not_allowed' })
            end
        end

        -- An empty box is a deliberate request to browse a register rather
        -- than search it (7.2) -- but only when the officer has said which
        -- register, by choosing an explicit type. A blank box with no type
        -- has nothing to derive from, so it stays a refusal rather than
        -- silently reading all three registers at once.
        local blank = service.isBlank(input.term)

        if blank and not explicit then
            return route.refuse(FredPD.ErrorCode.INVALID, { term = 'required' })
        end

        local term
        if blank then
            term = ''
        else
            term = service.normalizeTerm(input.term)
            if not term then
                return route.refuse(FredPD.ErrorCode.INVALID, { term = 'too_short' })
            end
        end

        local queryType, sources = service.plan(term, explicit)

        -- Each register is read only if this session may run that kind of
        -- query. A source the officer is not permitted is simply not searched:
        -- refusing the whole call would tell them the answer depends on a
        -- register they cannot see.
        local permitted = {}
        for source in pairs(sources) do
            if FredPD.Core.perms.satisfies(
                session.permissions, service.permissionFor(queryType, source)
            ) then
                permitted[source] = true
            end
        end

        if next(permitted) == nil then
            -- Logged, unlike the two malformed-input refusals above it. An
            -- officer reaching for a register they may not read is exactly what
            -- a misuse investigation looks for, and a refusal that leaves no
            -- trace is one nobody can find afterwards. A term too short and a
            -- type that is not a type are typing, not reaching, and logging
            -- them would bury this row in noise (7.2).
            logQuery(session, queryType, term, {}, 0, nil, nil)
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { type = 'not_allowed' })
        end

        -- Over-fetch: access filtering removes rows after the query and never
        -- says how many, so a page asked for at exactly `limit` comes back
        -- short (the access module is explicit that a caller which pages must
        -- over-fetch).
        local window, limit = registry.fetchWindow(input.limit)
        local context = service.context(term, queryType)
        local results = {}

        if permitted.person then
            collect(session, context, 'person', repo.searchPersons(session.agencyId, {
                mode = service.personMode(queryType),
                term = term,
                tokens = context.tokens,
                digits = context.digits,
                limit = window,
            }), results)
        end

        if permitted.vehicle then
            collect(session, context, 'vehicle',
                repo.searchVehicles(session.agencyId, term, window), results)
        end

        if permitted.firearm then
            collect(session, context, 'firearm',
                repo.searchFirearms(session.agencyId, term, window), results)
        end

        local page = service.rank(results, limit)

        local reason = service.blankToNull(input.reason)
        local caseNumber = service.blankToNull(input.caseNumber)

        if not reasonSatisfied(page, reason, caseNumber) then
            -- Logged as a query that found nothing, because that is what the
            -- officer was shown. The access module has already written its own
            -- audit entry for the records it refused (invariant 11).
            logQuery(session, queryType, term, {}, 0, nil, nil)

            return route.refuse(FredPD.ErrorCode.INVALID, { reason = 'required' })
        end

        -- Hot-file hits, for the rows the reader is allowed to see and no
        -- others: asking the database about the flags on a record that was
        -- filtered out would be the same disclosure by a slower route. One
        -- query per register for the whole page (spec 12).
        local reader = access.reader(session)
        local personIds = idsOfKind(page, 'person')
        local vehicleIds = idsOfKind(page, 'vehicle')

        local flags = repo.liveFlagsFor(session.agencyId, vehicleIds)
        local cautions = repo.liveCautionsFor(session.agencyId, personIds)

        -- The two sources 7.13 adds. Read across every agency, unlike the flags
        -- and cautions above: a wanted notice raised by another department is
        -- exactly the thing this officer needs to be told about.
        local efterlysningar = repo.liveEfterlysningarFor(personIds)
        local personSpaning = repo.liveSpaningFor('person', personIds)
        local vehicleSpaning = repo.liveSpaningFor('vehicle', vehicleIds)

        local now = os.time()

        --- Joins two hit lists. Both are sequences, so this keeps them one.
        local function merge(into, extra)
            for index = 1, #extra do into[#into + 1] = extra[index] end
            return into
        end

        for index = 1, #page do
            local row = page[index]

            if opened(row) then
                if row.kind == 'vehicle' then
                    row.hits = service.vehicleHits(visibleFlags(reader, flags[row.id] or {}), row.id)

                    merge(row.hits, service.spaningHits(
                        access.filterSearch(session, 'spaning', vehicleSpaning[row.id] or {}), now))
                elseif row.kind == 'firearm' then
                    row.hits = service.firearmHits(row)
                else
                    row.hits = service.personHits(
                        visibleCautions(session, reader, cautions[row.id] or {}), row.id
                    )

                    -- Through `access.filterSearch`, not the pure half.
                    --
                    -- The pure filter reads compartments, seals and grants off
                    -- the row, and only `Repo.prepare` puts them there -- so
                    -- filtering these with it enforced the classification
                    -- column and nothing else. A sealed or compartmented
                    -- efterlysning still became a red "detain on sight" banner
                    -- carrying its ground, and no read was audited.
                    --
                    -- Unlike the flags and cautions beside them, these are
                    -- standalone records with their own rows in
                    -- `fpd_record_compartments` and `fpd_record_seals`; a
                    -- caution is a child of a record already checked.
                    merge(row.hits, service.efterlysningHits(
                        access.filterSearch(session, 'efterlysning', efterlysningar[row.id] or {}), now))
                    merge(row.hits, service.spaningHits(
                        access.filterSearch(session, 'spaning', personSpaning[row.id] or {}), now))

                    redactAddress(session, row)
                end
            end
        end

        local hits = service.countHits(page)

        return {
            -- The log row this query wrote. A hit confirmation is bound to it
            -- (7.2), which is what lets the log say afterwards whether an
            -- officer acted on a confirmed record or on a lead.
            queryId = logQuery(session, queryType, term, page, hits, reason, caseNumber),
            type = queryType,
            derived = explicit == nil,
            sources = sortedKeys(permitted),
            results = page,
            hits = hits,
        }
    end,
})

-- =============================================================================
-- Confirming a hit (7.2)
-- =============================================================================

route.define({
    name = 'query.hit.confirm',
    perm = 'query.hit.confirm',
    schema = 'QueryHitConfirm',
    writes = true,
    -- A confirmation is what an officer points at afterwards to explain why
    -- they acted. A permission snapshot that may be half an hour stale is not
    -- the authority to write one (4.2).
    sensitive = true,
    audit = 'query.hit.confirmed',
    auditDetail = function(input)
        return {
            hitType = input.hitType,
            outcome = input.outcome,
            caseNumber = input.caseNumber,
        }
    end,
    handler = function(session, input)
        local err, fields = service.validateConfirm(input)
        if err then return route.refuse(err, fields) end

        -- The query the lead came from, when there was one. Scoped to this
        -- officer's own rows: the id arrives from the client, so without the
        -- check a confirmation could be attached to somebody else's query and
        -- the log would name the wrong person as having acted on it.
        --
        -- What is NOT checked, and is worth knowing when reading the log: that
        -- this query actually raised this hit. Nothing records which hits a
        -- query returned, so an officer could cite one of their own searches
        -- that never surfaced this record. It is not an access hole -- the hit
        -- still has to be one they can read, below -- but a query id in a
        -- confirmation row is the officer's claim about provenance rather than
        -- the server's knowledge of it.
        if input.queryId ~= nil and not repo.ownQuery(session, input.queryId) then
            return route.refuse(FredPD.ErrorCode.INVALID, { queryId = 'unknown' })
        end

        local target = repo.hitTarget(session.agencyId, input.hitType, input.hitId)
        if not target then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        -- The record first (4.5): an officer who may not read the vehicle may
        -- not confirm what is flagged on it, and `access.read` audits the read
        -- of a restricted record whichever way it goes (invariant 11). A
        -- refused record and a record that does not exist answer the same, on
        -- purpose.
        if not access.read(session, target.recordType, target.record) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        -- Then the hit itself, which carries its own classification and, on a
        -- caution, its own field gate. `not_found` rather than `forbidden`:
        -- "you may not confirm this" would tell the reader it is there, which
        -- is the whole of what the gate withholds.
        local child = target.child

        if child.fieldKey and not canSeeField(session, child.fieldKey) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        if not accessRules.canRead(access.reader(session), child) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        -- A flag that has been cleared, a caution that has been cancelled or a
        -- firearm that has been recovered between the query and the
        -- confirmation is a lead that has gone away. Writing "confirmed"
        -- against one would put an answer in the log to a question nobody can
        -- ask again.
        if not service.hitIsLive(input.hitType, child) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { hitId = 'stale' })
        end

        local existing = repo.confirmationFor(
            session.agencyId, input.queryId, input.hitType, input.hitId
        )

        if existing then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { hitId = 'exists' })
        end

        local id = repo.confirmHit(session, {
            queryId = input.queryId,
            hitType = input.hitType,
            hitId = input.hitId,
            -- The kind is read off the record, never taken from input: a client
            -- that could name it could file a confirmation saying a vehicle was
            -- confirmed stolen when the flag on it says something else
            -- (invariant 1).
            kind = target.kind,
            recordType = target.recordType,
            recordId = target.recordId,
            outcome = input.outcome,
            caseNumber = service.blankToNull(input.caseNumber),
            detail = service.blankToNull(input.detail),
        })

        return {
            id = id,
            hitType = input.hitType,
            hitId = input.hitId,
            kind = target.kind,
            recordType = target.recordType,
            recordId = target.recordId,
            outcome = input.outcome,
            -- What the banner turns into. True only for `confirmed`: a hit the
            -- holding agency could not answer is still a lead, and the
            -- interface must not draw it as anything else.
            confirmed = input.outcome == 'confirmed',
        }
    end,
})

-- =============================================================================
-- The query log (7.2)
-- =============================================================================

--- Two reads behind one route, with two different permissions.
---
--- "What have I run" is 7.2's recent-queries list, which every officer who can
--- run a query has: re-running your own last plate check is ordinary work, and
--- gating it on the misuse-investigation key would mean nobody but command ever
--- saw their own history.
---
--- "What has *she* run" is the misuse investigation, and that is
--- `query.log.view`. So the route asks only for the ability to query at all,
--- and the handler requires the stronger key the moment the question stops
--- being about the caller.
route.define({
    name = 'query.log',
    perm = 'query.person.run',
    schema = 'QueryLog',
    audit = 'query.log.read',
    auditDetail = function(input)
        -- Whose history was read, which is the question an audit of the
        -- misuse-investigation view has to be able to answer.
        return { mine = input.mine == true, discordId = input.discordId }
    end,
    handler = function(session, input)
        -- `mine` wins over any id in the input and takes the session's own
        -- (invariant 1): "what have I run" must not be a way to ask about
        -- somebody else by sending their id with it.
        local discordId = input.mine and session.discordId
            or service.blankToNull(input.discordId)

        -- Anything that is not "my own history" is the investigation view.
        -- Absent `discordId` means the whole agency's log, which is the
        -- broadest read of all and must not be the default for an officer who
        -- simply asked for their recent queries.
        if discordId ~= session.discordId
            and not FredPD.Core.perms.satisfies(session.permissions, 'query.log.view')
        then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { discordId = 'not_allowed' })
        end

        local entries, nextCursor = repo.queryLog(session.agencyId, {
            discordId = discordId,
            queryType = service.canonicalType(input.queryType),
            limit = input.limit,
        }, input.cursor)

        return { entries = entries, nextCursor = nextCursor }
    end,
})
