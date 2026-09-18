--- Anmälan och förundersökning routes (spec 7.7, 7.8).
---
--- The permission split here follows the workflow rather than the table:
---
---   * `rms.anmalan.view` -- read. Patrol work; an officer who cannot read the
---     anmälningar cannot follow up the one they attended.
---   * `rms.anmalan.create` -- write one. Also patrol.
---   * `rms.anmalan.edit.any` -- edit somebody else's draft. A supervisor grant,
---     because the ordinary author already reaches their own through
---     `Anmalan.canEdit`.
---   * `rms.anmalan.approve` -- approve or return. A supervisor grant, and one
---     that still does not let the holder approve their own work: that rule is
---     in `Anmalan.canApprove` and is not reachable by any permission.
---   * `inv.fu.*` -- the investigation. Opening one is an investigator's act;
---     deciding in one belongs to its förundersökningsledare.
---
--- Every read of a record goes through `access.read`, which applies the
--- clearance and compartment rules of 4.5 and audits the read when the record
--- is restricted (invariant 11). Doing that here rather than in the repo is
--- deliberate: the repo answers what the database holds, and the route decides
--- what this reader may be shown.

local route = FredPD.Core.route
local repo = FredPD.Repo.anmalan
local service = FredPD.Modules.anmalan
local brott = FredPD.Modules.brott
--- The record-level access module (4.5), in its two halves.
---
--- `FredPD.Repo.access` is the suite-wide entry point -- `read` for one row,
--- `filterSearch` for a list -- and it is what loads compartments, grants and
--- seals and writes the audit entry. `FredPD.Modules.access` is the pure half,
--- and `canClassify` lives there and only there. Calling it on the repo raises
--- "attempt to call a nil value" inside the handler's pcall, which surfaces as
--- `internal` rather than as anything that names the mistake -- which is
--- exactly how it went unnoticed in `registry/routes.lua`.
local access = FredPD.Repo.access
local accessRules = FredPD.Modules.access

--- The access record type an anmälan is filed under.
---
--- `report` rather than a new `anmalan` type, because the access module's
--- allowlist (0005, `RECORD_TYPES`) already carries it and a grant written
--- against `report` is what a supervisor means either way. The Swedish name is
--- the user-facing one; this is the internal key that grants are stored under,
--- and renaming it would orphan every grant already written.
local ANMALAN <const> = 'report'
local FU <const> = 'case'

--- The body of a version snapshot (7.7: "every version is kept").
---
--- Built here rather than in the repo because it needs the charges and the
--- people as the reader would see them, which is three queries the repo
--- exposes separately. Denormalised on purpose -- see `Repo.transition`.
local function snapshotOf(row, charges, personer)
    return json.encode({
        anmalan = row,
        brott = charges,
        personer = personer,
        -- The signature 7.7 asks for. The name and badge are taken from the
        -- roster at the moment of signing, so a later rank change does not
        -- rewrite a signature that has already been given.
        signedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    })
end

--- Reads an anmälan the session is allowed to see, or refuses.
---
--- @return table|nil row
--- @return table|nil refusal, ready to return
local function readable(session, id)
    local row = repo.byId(id, session.agencyId)
    if not row then return nil, route.refuse(FredPD.ErrorCode.NOT_FOUND) end

    local allowed = access.read(session, ANMALAN, row)
    if not allowed then return nil, route.refuse(FredPD.ErrorCode.RESTRICTED) end

    return allowed
end

-- -----------------------------------------------------------------------------
-- Reads
-- -----------------------------------------------------------------------------

route.define({
    name = 'anmalan.list',
    perm = 'rms.anmalan.view',
    schema = 'AnmalanList',
    handler = function(session, input)
        local rows = repo.list(session.agencyId, {
            status = input.status,
            -- `mine` is a filter the client asks for; the *identity* it filters
            -- on is the session's, never a field the client sent (invariant 1).
            createdBy = input.mine and session.discordId or nil,
            fuId = input.fuId,
            includeSupplements = input.includeSupplements,
        }, input.limit or 50)

        -- The access filter runs after the query and before the answer, which
        -- is invariant 4's order. A record above the reader's clearance is
        -- dropped or stubbed here, not hidden in the UI.
        return { anmalningar = access.filterSearch(session, ANMALAN, rows) }
    end,
})

route.define({
    name = 'anmalan.get',
    perm = 'rms.anmalan.view',
    schema = 'AnmalanGet',
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        local charges = repo.charges(row.id)

        -- The gemensam straffskala for what is charged (BrB 26:2), computed
        -- through the brott module's service rather than here: one
        -- implementation, and busted tests it.
        local skalor = {}
        for index = 1, #charges do
            skalor[index] = brott.straffskala(charges[index])
            charges[index].citation = brott.citation(charges[index])
        end

        -- What this session may do with this record, answered here rather
        -- than left for the screen to infer.
        --
        -- The alternative was shipping the viewer's Discord id to the NUI so it
        -- could compare authors itself. `Session` deliberately carries no
        -- discordId -- it is an identifier the interface has no use for -- and
        -- "what a session may do is the server's answer" (spec 6.4) is the
        -- rule this whole codebase is built on. So the server answers.
        --
        -- `ownReport` is separate from `canApprove` because the screen says
        -- different things about them. Not holding the grant is a role
        -- question; having written the thing yourself is a rule no grant
        -- reaches, and an officer refused with a bare `forbidden` goes and asks
        -- for a permission that would not have helped.
        local hasApprove = FredPD.Core.perms.satisfies(session.permissions, 'rms.anmalan.approve')
        local editAny = FredPD.Core.perms.satisfies(session.permissions, 'rms.anmalan.edit.any')

        return {
            anmalan = row,
            brott = charges,
            personer = repo.personer(row.id),
            supplements = repo.supplements(row.id, session.agencyId),
            straffskala = #skalor > 0 and brott.gemensamStraffskala(skalor) or nil,
            aklagareIndicated = service.aklagareIndicated(skalor),
            may = {
                approve = service.canApprove(row, session.discordId, hasApprove),
                submit = service.canSubmit(row, session.discordId, editAny),
                edit = service.canEdit(row, session.discordId, editAny),
                ownReport = row.createdBy == session.discordId,
            },
        }
    end,
})

route.define({
    name = 'anmalan.versions',
    perm = 'rms.anmalan.view',
    schema = 'AnmalanGet',
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        return { versions = repo.versions(row.id) }
    end,
})

-- -----------------------------------------------------------------------------
-- Writing one
-- -----------------------------------------------------------------------------

route.define({
    name = 'anmalan.create',
    perm = 'rms.anmalan.create',
    schema = 'AnmalanCreate',
    writes = true,
    audit = 'anmalan.created',
    subjectType = ANMALAN,
    auditDetail = function(input) return { title = input.title, fuId = input.fuId } end,
    handler = function(session, input)
        -- A classification above the author's own clearance would be a record
        -- they could write and then not read (4.5).
        if not accessRules.canClassify(access.reader(session), input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'over_clearance' })
        end

        -- A tilläggsuppgift: the parent must exist, must be readable, and must
        -- not close a cycle. The cycle check is the one the schema cannot hold
        -- (0009 says why).
        if input.parentId then
            local parent, refusal = readable(session, input.parentId)
            if not parent then return refusal end

            local ok, why = service.parentIsAllowed(nil, input.parentId, function(id)
                return repo.parentOf(id, session.agencyId)
            end)

            if not ok then return route.refuse(FredPD.ErrorCode.INVALID, { parentId = why }) end
        end

        local row = repo.create(input, session)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = row.id, number = row.number, anmalan = row }
    end,
})

route.define({
    name = 'anmalan.update',
    perm = 'rms.anmalan.view',
    schema = 'AnmalanUpdate',
    writes = true,
    audit = 'anmalan.updated',
    subjectType = ANMALAN,
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        -- `editAny` is resolved here and handed to the service, which holds no
        -- session logic of its own.
        local editAny = FredPD.Core.perms.satisfies(session.permissions, 'rms.anmalan.edit.any')

        local ok, why = service.canEdit(row, session.discordId, editAny)
        if not ok then
            return route.refuse(
                why == 'locked' and FredPD.ErrorCode.CONFLICT or FredPD.ErrorCode.FORBIDDEN,
                { status = why })
        end

        if input.classification and not accessRules.canClassify(access.reader(session), input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'over_clearance' })
        end

        -- Optimistic locking. A zero row count means somebody else moved the
        -- version between the read above and this write, which is a conflict
        -- the officer can see rather than an overwrite they cannot.
        if repo.update(row.id, session.agencyId, input, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})

-- -----------------------------------------------------------------------------
-- The workflow
-- -----------------------------------------------------------------------------

--- The body every anmälan transition shares.
---
--- The handler is factored out and the `route.define` calls are **not**, which
--- is deliberate rather than clumsy. `tools/wiring-check.ts` reads route names
--- as string literals out of each definition; a factory that passed the name as
--- a parameter hid all three routes from it, and from the checks that a route
--- has a schema, an NUI callback and a permission some group is granted.
--- A route the tooling cannot see is a route whose permission can quietly be
--- granted to nobody. So the shared part is shared and the declarations stay
--- where a reader -- and a grep -- can find them.
---
--- @param action string 'submit', 'return' or 'approve'
--- @param guard function(row, session) -> boolean, reason
local function runTransition(session, input, action, guard)
    local row, refusal = readable(session, input.id)
    if not row then return refusal end

    local ok, why = guard(row, session)
    if not ok then
        return route.refuse(
            why == 'locked' and FredPD.ErrorCode.CONFLICT or FredPD.ErrorCode.FORBIDDEN,
            { status = why })
    end

    local toStatus = service.nextStatus(row.status, action)
    if not toStatus then
        return route.refuse(FredPD.ErrorCode.CONFLICT, { status = 'not_allowed' })
    end

    local snapshot = snapshotOf(row, repo.charges(row.id), repo.personer(row.id))

    if not repo.transition(row.id, session.agencyId, toStatus, session.discordId,
                           snapshot, input.version, input.note) then
        return route.refuse(FredPD.ErrorCode.CONFLICT)
    end

    return { id = row.id, status = toStatus }
end

--- Submitting is the last edit, so it is the author's to make.
local function guardSubmit(row, session)
    local editAny = FredPD.Core.perms.satisfies(session.permissions, 'rms.anmalan.edit.any')
    return service.canSubmit(row, session.discordId, editAny)
end

--- Approving and returning are the same second pair of eyes -- including the
--- rule that they cannot be the author's own. `true` for the permission,
--- because the route layer already refused anybody without the grant; what this
--- still decides is the part no permission reaches.
local function guardReview(row, session)
    return service.canApprove(row, session.discordId, true)
end

route.define({
    name = 'anmalan.submit',
    perm = 'rms.anmalan.create',
    schema = 'AnmalanGet',
    writes = true,
    audit = 'anmalan.submitted',
    subjectType = ANMALAN,
    handler = function(session, input)
        return runTransition(session, input, 'submit', guardSubmit)
    end,
})

route.define({
    name = 'anmalan.atersand',
    perm = 'rms.anmalan.approve',
    schema = 'AnmalanReturn',
    writes = true,
    audit = 'anmalan.returned',
    subjectType = ANMALAN,
    handler = function(session, input)
        return runTransition(session, input, 'return', guardReview)
    end,
})

route.define({
    name = 'anmalan.approve',
    perm = 'rms.anmalan.approve',
    schema = 'AnmalanGet',
    writes = true,
    -- Approving locks a record that is later read as having been reviewed. A
    -- stale Discord snapshot must not be able to produce one (4.2).
    sensitive = true,
    audit = 'anmalan.approved',
    subjectType = ANMALAN,
    handler = function(session, input)
        return runTransition(session, input, 'approve', guardReview)
    end,
})

-- -----------------------------------------------------------------------------
-- Charges and people
-- -----------------------------------------------------------------------------

route.define({
    name = 'anmalan.charges.set',
    perm = 'rms.anmalan.view',
    schema = 'AnmalanCharges',
    writes = true,
    audit = 'anmalan.charges.set',
    subjectType = ANMALAN,
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        local editAny = FredPD.Core.perms.satisfies(session.permissions, 'rms.anmalan.edit.any')

        local ok, why = service.canEdit(row, session.discordId, editAny)
        if not ok then
            return route.refuse(
                why == 'locked' and FredPD.ErrorCode.CONFLICT or FredPD.ErrorCode.FORBIDDEN,
                { status = why })
        end

        -- Duplicates survive: three counts of one offence is three rows, which
        -- is what BrB 26:2 computes over.
        local ids, reason = brott.parseIds(input.brottIds, 25)
        if not ids then return route.refuse(FredPD.ErrorCode.INVALID, { brottIds = reason }) end

        local rows = FredPD.Repo.brott.byIds(ids, session.agencyId)
        local catalogue = brott.expandCharges(ids, rows)
        if not catalogue then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { brottIds = 'unknown' })
        end

        -- Per-count detail arrives as three parallel lists, because the
        -- validator is flat. They must line up with the ids or a charge would
        -- silently be attributed to the wrong person.
        local stages = input.stages or {}
        local personIds = input.personIds or {}

        if (#stages > 0 and #stages ~= #ids) or (#personIds > 0 and #personIds ~= #ids) then
            return route.refuse(FredPD.ErrorCode.INVALID, { stages = 'length_mismatch' })
        end

        local charges = {}

        for index = 1, #ids do
            local stage = stages[index] or 'fullbordat'

            -- BrB 23: försök and förberedelse only where the statute makes them
            -- punishable, which the catalogue row says.
            if not service.stageIsAvailable(catalogue[index], stage) then
                return route.refuse(FredPD.ErrorCode.INVALID, { stages = 'stage_unavailable' })
            end

            charges[index] = {
                brottId = ids[index],
                stage = stage,
                personId = tonumber(personIds[index]),
                note = nil,
            }
        end

        if not repo.replaceCharges(row.id, charges, session.discordId) then
            return route.refuse(FredPD.ErrorCode.INTERNAL)
        end

        return { id = row.id, count = #charges }
    end,
})

route.define({
    name = 'anmalan.person.set',
    perm = 'rms.anmalan.view',
    schema = 'AnmalanPerson',
    writes = true,
    audit = 'anmalan.person.set',
    subjectType = ANMALAN,
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        local editAny = FredPD.Core.perms.satisfies(session.permissions, 'rms.anmalan.edit.any')

        local ok, why = service.canEdit(row, session.discordId, editAny)
        if not ok then
            return route.refuse(
                why == 'locked' and FredPD.ErrorCode.CONFLICT or FredPD.ErrorCode.FORBIDDEN,
                { status = why })
        end

        if not service.isRoll(input.roll) then
            return route.refuse(FredPD.ErrorCode.INVALID, { roll = 'unknown' })
        end

        repo.setPerson(row.id, input.personId, input.roll, input.note, session.discordId)

        return { id = row.id }
    end,
})

route.define({
    name = 'anmalan.person.remove',
    perm = 'rms.anmalan.view',
    schema = 'AnmalanPerson',
    writes = true,
    audit = 'anmalan.person.removed',
    subjectType = ANMALAN,
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        local editAny = FredPD.Core.perms.satisfies(session.permissions, 'rms.anmalan.edit.any')

        local ok, why = service.canEdit(row, session.discordId, editAny)
        if not ok then
            return route.refuse(
                why == 'locked' and FredPD.ErrorCode.CONFLICT or FredPD.ErrorCode.FORBIDDEN,
                { status = why })
        end

        repo.removePerson(row.id, input.personId, input.roll)

        return { id = row.id }
    end,
})

-- -----------------------------------------------------------------------------
-- Förundersökningen
-- -----------------------------------------------------------------------------

route.define({
    name = 'fu.list',
    perm = 'inv.fu.view',
    schema = 'FuList',
    handler = function(session, input)
        local rows = repo.fuList(session.agencyId, {
            status = input.status,
            fuLedare = input.mine and session.discordId or nil,
        }, input.limit or 50)

        return { forundersokningar = access.filterSearch(session, FU, rows) }
    end,
})

route.define({
    name = 'fu.get',
    perm = 'inv.fu.view',
    schema = 'FuGet',
    handler = function(session, input)
        local row = repo.fuById(input.id, session.agencyId)
        if not row then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        local allowed = access.read(session, FU, row)
        if not allowed then return route.refuse(FredPD.ErrorCode.RESTRICTED) end

        return {
            fu = allowed,
            anmalningar = access.filterSearch(session, ANMALAN,
                repo.list(session.agencyId, { fuId = row.id, includeSupplements = true }, 100)),
        }
    end,
})

route.define({
    name = 'fu.create',
    perm = 'inv.fu.open',
    schema = 'FuCreate',
    writes = true,
    audit = 'fu.opened',
    subjectType = FU,
    auditDetail = function(input) return { title = input.title, ledareKind = input.ledareKind } end,
    handler = function(session, input)
        if not accessRules.canClassify(access.reader(session), input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'over_clearance' })
        end

        local row = repo.fuCreate(input, session)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = row.id, number = row.number, fu = row }
    end,
})

route.define({
    name = 'fu.assign',
    perm = 'inv.fu.assign',
    schema = 'FuAssign',
    writes = true,
    sensitive = true,
    audit = 'fu.assigned',
    subjectType = FU,
    handler = function(session, input)
        local row = repo.fuById(input.id, session.agencyId)
        if not row then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        if not service.fuIsOpen(row) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { status = 'fu_closed' })
        end

        if repo.fuAssign(row.id, session.agencyId, input.fuLedare,
                         input.ledareKind, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})

--- The body every förundersökning decision shares.
---
--- Declared out longhand below for the same reason the anmälan transitions are:
--- a route name that is not a literal is a route `tools/wiring-check.ts` cannot
--- see.
local function runFuDecision(session, input, action)
    local row = repo.fuById(input.id, session.agencyId)
    if not row then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

    local ledAny = FredPD.Core.perms.satisfies(session.permissions, 'inv.fu.assign')

    local ok, why = service.canDecide(row, session.discordId, ledAny)
    if not ok then
        return route.refuse(
            why == 'fu_closed' and FredPD.ErrorCode.CONFLICT or FredPD.ErrorCode.FORBIDDEN,
            { status = why })
    end

    local toStatus = service.nextFuStatus(row.status, action)
    if not toStatus then
        return route.refuse(FredPD.ErrorCode.CONFLICT, { status = 'not_allowed' })
    end

    -- A nedläggning without a stated ground is the decision nobody can be asked
    -- about afterwards. The reason is a locale key, never a sentence
    -- (invariant 6).
    if toStatus == 'nedlagd' and not input.reason then
        return route.refuse(FredPD.ErrorCode.INVALID, { reason = 'required' })
    end

    if repo.fuTransition(row.id, session.agencyId, toStatus, session.discordId,
                         input.reason, input.note, input.version) == 0 then
        return route.refuse(FredPD.ErrorCode.CONFLICT)
    end

    return { id = row.id, status = toStatus }
end

route.define({
    name = 'fu.slutdelge',
    perm = 'inv.fu.lead',
    schema = 'FuDecision',
    writes = true,
    sensitive = true,
    audit = 'fu.slutdelgiven',
    subjectType = FU,
    handler = function(session, input)
        return runFuDecision(session, input, 'slutdelge')
    end,
})

route.define({
    name = 'fu.redovisa',
    perm = 'inv.fu.lead',
    schema = 'FuDecision',
    writes = true,
    sensitive = true,
    audit = 'fu.redovisad',
    subjectType = FU,
    handler = function(session, input)
        return runFuDecision(session, input, 'redovisa')
    end,
})

route.define({
    name = 'fu.lagg_ned',
    perm = 'inv.fu.lead',
    schema = 'FuDecision',
    writes = true,
    -- The decision a prosecutor is asked about.
    sensitive = true,
    audit = 'fu.nedlagd',
    subjectType = FU,
    handler = function(session, input)
        return runFuDecision(session, input, 'lagg_ned')
    end,
})
