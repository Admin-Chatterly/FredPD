--- Reports that start themselves (spec 7.7).
---
--- An arrest, or a call cleared with an arrest, a fine or "report taken",
--- is always followed by an anmälan -- and the officer used to have to
--- remember to start one, then retype the call, the place and the person.
--- Now the draft is there waiting: titled, linked to the call, with the
--- arrested person on it as a suspect, and the officer is told its number.
--- It is a draft (`utkast`) written as the officer themselves: nothing is
--- submitted, and they finish it on the Records screen.
---
--- The same rules as writing one by hand, applied without a route:
---
---   * only for an officer signed on now whose Discord roles grant
---     `rms.anmalan.create` on a snapshot that is not stale -- a dispatcher
---     clearing a call from the console gets no report under their name;
---   * filed no lower than the arrest, the call or the person it names (4.5);
---   * added to an existing draft on the call only if this officer may edit
---     it and it is classified at least as high; otherwise they get their own;
---   * every write audited.
---
--- Listens to the server-local events other modules already fire (spec 14),
--- so neither the custody module nor dispatch reaches into this one's tables.

local repo = FredPD.Repo.anmalan
local service = FredPD.Modules.anmalan

local CREATE <const> = 'rms.anmalan.create'

--- The officer's open session, if it may write a report right now.
local function writer(agencyId, discordId)
    for _, session in pairs(FredPD.Core.session.all()) do
        if session.agencyId == agencyId and session.discordId == discordId then
            if FredPD.Core.session.isStale(session) then return nil end
            if not FredPD.Core.perms.satisfies(session.permissions, CREATE) then return nil end

            return session
        end
    end

    return nil
end

local function rank(level)
    return FredPD.Modules.access.clearanceRank(level)
end

--- The officer's live call, if they are on one: the arrest belongs with it.
local function callOf(agencyId, discordId)
    local cad = FredPD.Repo.cad
    local assignment = cad and cad.activeAssignment(agencyId, discordId)

    return assignment and assignment.callId or nil
end

local function tell(agencyId, discordId, number)
    FredPD.Core.push.notifyWhere(function(other)
        return other.agencyId == agencyId and other.discordId == discordId
    end, 'anmalan.notify.draft', { number = number }, { type = 'inform' })
end

local function audit(session, action, anmalanId, detail)
    detail.automatic = true

    FredPD.Core.audit.write({
        action = action,
        discordId = session.discordId,
        agencyId = session.agencyId,
        subjectType = 'report',
        subjectId = tostring(anmalanId),
        detail = detail,
    })
end

--- The call's draft this officer may add to, or a new one of theirs.
--- @return table|nil row, boolean created
local function draftFor(session, callId, fields)
    local existing = repo.forCall(session.agencyId, callId)

    local reusable = existing
        and service.canEdit({ status = existing.status, createdBy = existing.createdBy }, session.discordId, false)
        and (rank(existing.classification) or 0) >= (rank(fields.classification) or 0)

    if reusable then return existing, false end

    local row = repo.create({
        title = fields.title,
        callId = callId,
        occurredPlace = fields.place,
        classification = fields.classification,
    }, session)

    -- `create` reads its row back as this officer's newest; one they wrote by
    -- hand in the same instant would be a different report. Refuse rather
    -- than put a person on the wrong one.
    if not row or row.title ~= fields.title or row.callId ~= callId then return nil, false end

    audit(session, 'anmalan.created', row.id, { callId = callId })

    return row, true
end

AddEventHandler('fredpd:gripande', function(payload)
    if type(payload) ~= 'table' or not payload.agencyId or not payload.discordId then return end

    local ok, err = pcall(function()
        local session = writer(payload.agencyId, payload.discordId)
        if not session then return end

        local callId = callOf(payload.agencyId, payload.discordId)

        local row, created = draftFor(session, callId, {
            title = FredPD.t('anmalan.autoTitle.arrest'),
            classification = service.highestClassification(
                { payload.classification, payload.personClassification }, rank),
        })
        if not row then return end

        if payload.personId then
            repo.setPerson(row.id, payload.personId, 'misstankt', nil, session.discordId)
            audit(session, 'anmalan.person.set', row.id, {
                personId = payload.personId, roll = 'misstankt', frihetId = payload.frihetId,
            })
        end

        if created then tell(payload.agencyId, payload.discordId, row.number) end
    end)

    if not ok then print(('[fredpd] anmalan: arrest draft failed: %s'):format(tostring(err))) end
end)

AddEventHandler('fredpd:callCleared', function(payload)
    if type(payload) ~= 'table' or not payload.agencyId or not payload.discordId then return end
    if not service.dispositionNeedsReport(payload.disposition) then return end

    local ok, err = pcall(function()
        local session = writer(payload.agencyId, payload.discordId)
        if not session then return end

        local row, created = draftFor(session, payload.callId, {
            title = FredPD.t('anmalan.autoTitle.call', {
                type = FredPD.t('cad.callType.' .. tostring(payload.type)),
                number = payload.callNumber or '',
            }),
            place = payload.locationText,
            classification = service.highestClassification({ payload.classification }, rank),
        })

        if row and created then tell(payload.agencyId, payload.discordId, row.number) end
    end)

    if not ok then print(('[fredpd] anmalan: call draft failed: %s'):format(tostring(err))) end
end)
