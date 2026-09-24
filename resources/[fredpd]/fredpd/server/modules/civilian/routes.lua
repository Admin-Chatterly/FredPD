--- Civilian mode (spec 7.29): a police front desk for everyone.
---
--- A `public_counter` placement is the one entrance that is not for officers.
--- At it, any player sees their own citations and the court's decisions about
--- them, and hands in a stolen-property report or a complaint. Officers read
--- what was handed in from an inbox.
---
--- The desk routes are the subject tier (ADR-023): the player at a desk
--- usually has no session, and who they are is established by the wrapper --
--- standing at a public desk, as the framework's character for that player --
--- never by anything the client sends (invariant 1). The handler is handed
--- that subject and reads only what is keyed on it. What they are shown is
--- their own, and only what is not restricted: the modules that own it decide
--- (`*ForSubject`).

local route = FredPD.Core.route
local repo = FredPD.Repo.civilian
local service = FredPD.Modules.civilian

local function config()
    return FredPD.Config.server.civilian or {}
end

--- Every player learns where the desks are, officers included. Geometry only
--- (ADR-006): no record, so the public tier.
route.public({
    name = 'placements.public',
    schema = 'PlacementsPublic',
    limit = { per = 6, window = 60 },
    handler = function()
        return { placements = FredPD.Core.placements.public() }
    end,
})

route.subject({
    name = 'civilian.overview',
    schema = 'CivilianOverview',
    limit = { per = 10, window = 60 },
    handler = function(subject)
        local agency = FredPD.Core.agencies.get(subject.agencyId)
        return {
            name = subject.name,
            agencyName = agency and agency.name or subject.agencyId,
            citations = FredPD.Modules.ordningsbotForSubject(subject.agencyId, subject.personId),
            court = FredPD.Modules.courtForSubject(subject.agencyId, subject.personId),
            reports = repo.mine(subject.agencyId, subject.identifier, 25),
        }
    end,
})

--- Reports being written, per character: one at a time, so two presses of
--- Submit are not two reports (`repo.insert` reads back by reporter).
local filing = {}

--- Told to whoever reads this kind, in the desk's agency, and nobody else: a
--- complaint about the police goes to internal affairs, not to the shift.
local function announce(agencyId, kind, number)
    FredPD.Core.push.notifyPermission(service.readPermission(kind), 'public.notify.received',
        { number = number }, nil, function(session) return session.agencyId == agencyId end)
end

route.subject({
    name = 'civilian.report.create',
    schema = 'CivilianReportCreate',
    limit = { per = 3, window = 600 },
    audit = 'public.report.received',
    subjectType = 'public_report',
    auditDetail = function(input, result) return { number = result.number, kind = input.kind } end,
    handler = function(subject, input)
        local report, fields = service.validateReport(input, os.time())
        if not report then return route.refuse(FredPD.ErrorCode.INVALID, fields) end

        -- The lock before the count: a second request must not read the
        -- count, wait on the database, and insert past the cap.
        if filing[subject.identifier] then return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'in_progress' }) end
        filing[subject.identifier] = true

        local ok, row = pcall(function()
            if repo.countToday(subject.agencyId, subject.identifier) >= (tonumber(config().perDay) or 5) then
                return 'too_many'
            end

            local agency = FredPD.Core.agencies.get(subject.agencyId)
            report.reporterIdentifier = subject.identifier
            report.reporterPersonId = subject.personId
            report.reporterName = subject.name
            return repo.insert(report, subject.agencyId, agency and agency.shortName or subject.agencyId)
        end)

        filing[subject.identifier] = nil
        if not ok then error(row) end
        if row == 'too_many' then return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'too_many' }) end
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        -- The report is filed: a failed notification must not lose its
        -- receipt audit row.
        pcall(announce, subject.agencyId, report.kind, row.number)

        return { id = row.id, number = row.number }
    end,
})

-- -----------------------------------------------------------------------------
-- The inbox (officers)
-- -----------------------------------------------------------------------------

--- The kinds this session may read.
local function readableKinds(session)
    local kinds = {}
    for _, kind in ipairs({ 'stolen_property', 'complaint' }) do
        if FredPD.Core.perms.satisfies(session.permissions, service.readPermission(kind)) then
            kinds[#kinds + 1] = kind
        end
    end
    return kinds
end

route.define({
    name = 'public.report.list',
    perm = 'public.report.view',
    schema = 'PublicReportList',
    handler = function(session, input)
        local reports = repo.inbox(session.agencyId, readableKinds(session), input.status, input.limit or 50)
        local perms = FredPD.Core.perms
        local complaints = {}

        for _, row in ipairs(reports) do
            -- Whether this reader may close it: drawn from here, re-checked
            -- by `public.report.handle`.
            row.canHandle = perms.satisfies(session.permissions, service.handlePermission(row.kind))
            if row.kind == 'complaint' then complaints[#complaints + 1] = row.number end
        end

        -- A complaint about the police is internal-affairs material: who read
        -- which is on the record, as a restricted read would be (invariant 11).
        if #complaints > 0 then
            FredPD.Core.audit.write({
                action = 'public.report.complaints_read',
                discordId = session.discordId,
                agencyId = session.agencyId,
                subjectType = 'public_report',
                detail = { numbers = complaints },
            })
        end

        return { reports = reports }
    end,
})

route.define({
    name = 'public.report.handle',
    perm = 'public.report.view',
    schema = 'PublicReportHandle',
    writes = true,
    limit = { per = 20, window = 60 },
    audit = 'public.report.handled',
    subjectType = 'public_report',
    auditDetail = function(input, result)
        return { number = result.number, outcome = input.outcome, anmalanId = input.anmalanId }
    end,
    handler = function(session, input)
        local row = repo.byId(input.id, session.agencyId)
        -- One this session may not read is not one it may learn exists.
        if not row or not FredPD.Core.perms.satisfies(session.permissions, service.readPermission(row.kind)) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        if not FredPD.Core.perms.satisfies(session.permissions, service.handlePermission(row.kind)) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN)
        end

        -- An anmälan written from it must be one this officer may read.
        if input.anmalanId then
            local anmalan = FredPD.Modules.anmalanReadable(session, input.anmalanId)
            if not anmalan then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { anmalanId = 'unknown' }) end
        end

        local changed = repo.handle(row.id, session.agencyId, input.version, input.outcome,
            session.discordId, input.note, input.anmalanId)
        if (changed or 0) == 0 then return route.refuse(FredPD.ErrorCode.CONFLICT, { version = 'stale' }) end

        return { id = row.id, number = row.number }
    end,
})
