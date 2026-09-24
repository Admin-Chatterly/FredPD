--- Printing (spec 7.28, ADR-020).
---
--- `document.print` asks the module that owns the record for its printed
--- form (`service.register`), numbers it, keeps it (`fpd_documents`), and
--- hands over a copy:
---
---   * **paper**: an inventory item whose metadata carries the document as
---     printed, so whoever holds the paper can read it (`client/main.lua`,
---     `readPaper`) -- a copy handed across a counter, not a window onto the
---     record. Because it leaves the access domain for good, only a record
---     at or below `documents.paperCeiling`, in no compartment, not sealed
---     and not opened by break-glass may go to paper (`service.copyRule`);
---   * **pdf**: rendered by the gateway, with letterhead, page numbers, the
---     document number and the classification on every page. The link is a
---     bearer link for as long as `gateway.mediaLinkSeconds` says: whoever
---     has it can fetch the file. A restricted record's PDF is an export
---     (11.1) and needs `document.export.restricted`.
---
--- `document.preview` runs the same printer and says what the page would
--- show and which copies may be made, and keeps nothing (6.4, print preview).

local route = FredPD.Core.route
local repo = FredPD.Repo.documents
local service = FredPD.Modules.documents

local EXPORT_RESTRICTED <const> = 'document.export.restricted'

local function config()
    return FredPD.Config.server.documents or {}
end

local function paperItem()
    return config().paperItem or 'fredpd_paper'
end

--- Prints in flight, per officer and record: two presses of Print must not
--- race each other (`repo.insert` reads its row back by officer and record,
--- which is only unambiguous while this lock is held).
local printing = {}

--- Asks the owning module for its page, then decides which copies it may
--- have. The printer's refusal is its own: a record the officer may not read
--- is refused exactly as its own read refuses it.
---
--- @return table|nil document, table|nil rule, table|nil refusal
local function prepare(session, input)
    local printer = service.printerFor(input.kind)
    if not printer then return nil, nil, route.refuse(FredPD.ErrorCode.NOT_FOUND, { kind = 'unknown' }) end

    local document, refusal = printer(session, input.id)
    if not document then return nil, nil, refusal end

    local control = document.control
    local rule = service.copyRule(control, {
        paperCeiling = config().paperCeiling,
        breakglass = type(control) == 'table'
            and FredPD.Repo.access.viaBreakglass(session, document.recordType, control.id) or false,
        mayExportRestricted = FredPD.Core.perms.satisfies(session.permissions, EXPORT_RESTRICTED),
    })

    -- What the server can make at all, on top of what this record may have.
    if rule.paper == true and not FredPD.Bridge.inventory.knowsItem(paperItem()) then rule.paper = 'no_paper' end
    if rule.pdf == true and not FredPD.Bridge.gateway.service.isEnabled() then rule.pdf = 'pdf_off' end

    return document, rule
end

--- The page as it is printed: the same for the preview, the paper and the
--- document row. The body is cut to what a paper copy carries.
local function printedFor(session, document)
    local agency = FredPD.Core.agencies.get(session.agencyId)
    local body, cut = service.bounded(document.body, service.PAPER_TEXT_LIMIT)

    return {
        title = document.title,
        fields = document.fields,
        body = body,
        cut = cut,
        -- `copyRule` has already refused every copy of a record with no
        -- recognised classification; the preview still needs a word to show.
        classification = type(document.control) == 'table' and document.control.classification or 'internal',
        agency = agency and agency.name or session.agencyId,
        printedAt = os.date('%Y-%m-%d %H:%M'),
        -- Somebody is always named: an officer with no callsign yet is
        -- named by their roster name.
        printedBy = session.callsign or session.name or '',
    }
end

--- A refusal saying why this copy may not be made.
local function copyRefusal(reason)
    if reason == 'export_restricted' then
        return route.refuse(FredPD.ErrorCode.FORBIDDEN, { copy = reason })
    end

    return route.refuse(FredPD.ErrorCode.CONFLICT, { copy = reason })
end

route.define({
    name = 'document.capabilities',
    perm = 'document.print',
    schema = 'DocumentCapabilities',
    handler = function()
        return {
            paper = FredPD.Bridge.inventory.knowsItem(paperItem()),
            pdf = FredPD.Bridge.gateway.service.isEnabled(),
        }
    end,
})

route.define({
    name = 'document.preview',
    perm = 'document.print',
    schema = 'DocumentPreview',
    limit = { per = 20, window = 60 },
    handler = function(session, input)
        local document, rule, refusal = prepare(session, input)
        if not document then return refusal end

        local printed = printedFor(session, document)

        return {
            document = printed,
            copies = { paper = rule.paper, pdf = rule.pdf },
        }
    end,
})

route.define({
    name = 'document.print',
    perm = 'document.print',
    schema = 'DocumentPrint',
    writes = true,
    limit = { per = 6, window = 60 },
    audit = 'document.printed',
    subjectType = 'document',
    -- Only a print that happened reaches here; a refusal is audited as one.
    auditDetail = function(input, result)
        return {
            kind = input.kind,
            recordId = input.id,
            copy = input.copy,
            number = result.number,
            classification = result.classification,
        }
    end,
    handler = function(session, input)
        local document, rule, refusal = prepare(session, input)
        if not document then return refusal end

        local allowed = rule[input.copy]
        if allowed ~= true then return copyRefusal(allowed) end

        local key = ('%s:%s:%d'):format(session.discordId, input.kind, input.id)
        if printing[key] then return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'in_progress' }) end
        printing[key] = true

        local ok, result = pcall(function()
            local printed = printedFor(session, document)

            local row = repo.insert({
                kind = input.kind,
                subjectId = input.id,
                title = document.title,
                classification = printed.classification,
                payload = json.encode(printed),
            }, session)
            if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

            printed.number = row.number

            if input.copy == 'paper' then
                local given = FredPD.Bridge.inventory.addItem(session.src, paperItem(), {
                    label = document.title,
                    description = row.number,
                    fredpd = printed,
                })

                if not given then
                    repo.remove(row.id, session.agencyId)
                    return route.refuse(FredPD.ErrorCode.CONFLICT, { copy = 'no_paper' })
                end

                return { id = row.id, number = row.number, classification = printed.classification }
            end

            -- A PDF, from the gateway, rendered now or not at all.
            local gateway = FredPD.Bridge.gateway.service
            local rendered, pdf = gateway.renderPdfNow({
                title = document.title,
                fields = document.fields,
                body = document.body,
                classification = FredPD.t('records.classification.' .. printed.classification),
                letterhead = printed.agency,
                documentNumber = row.number,
                pageLabel = FredPD.t('document.pdf.page'),
                printedLabel = FredPD.t('document.pdf.printed', { at = printed.printedAt, by = printed.printedBy }),
            })

            if not rendered or type(pdf) ~= 'table' or type(pdf.mediaRef) ~= 'string' then
                repo.remove(row.id, session.agencyId)
                return route.refuse(FredPD.ErrorCode.CONFLICT, { copy = 'pdf_unavailable' })
            end

            repo.setMedia(row.id, session.agencyId, pdf.mediaRef)

            local now = os.time()
            return {
                id = row.id,
                number = row.number,
                classification = printed.classification,
                url = gateway.downloadUrl(pdf.mediaRef, false, now),
                expiresAt = now + gateway.linkSeconds(),
            }
        end)

        printing[key] = nil
        if not ok then error(result) end

        return result
    end,
})
