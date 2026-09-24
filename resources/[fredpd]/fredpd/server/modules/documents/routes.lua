--- Printing (spec 7.28, ADR-020).
---
--- `document.print` asks the module that owns the record for its printed
--- form (`service.register`), numbers it, keeps it (`fpd_documents`), and
--- hands over a copy:
---
---   * **paper**: an inventory item whose metadata carries the document as
---     printed, so whoever holds the paper can read it (`client/main.lua`,
---     `readPaper`) -- a copy handed across a counter, not a window onto the
---     record, which goes on being read through its own access check;
---   * **pdf**: rendered by the gateway, with letterhead, page numbers, the
---     document number and the classification on every page, and a link signed
---     for this officer (ADR-019's download links).

local route = FredPD.Core.route
local repo = FredPD.Repo.documents
local service = FredPD.Modules.documents

local function config()
    return FredPD.Config.server.documents or {}
end

local function paperItem()
    return config().paperItem or 'fredpd_paper'
end

--- Prints in flight, per officer and record: two presses of Print must not
--- race each other to the same number (`repo.insert` reads back by record).
local printing = {}

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
    name = 'document.print',
    perm = 'document.print',
    schema = 'DocumentPrint',
    writes = true,
    limit = { per = 6, window = 60 },
    audit = 'document.printed',
    subjectType = 'document',
    auditDetail = function(input, result)
        return {
            kind = input.kind,
            recordId = input.id,
            copy = input.copy,
            number = type(result) == 'table' and result.number or nil,
        }
    end,
    handler = function(session, input)
        local printer = service.printerFor(input.kind)
        if not printer then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { kind = 'unknown' }) end

        -- The owner reads the record through its own access check and says
        -- what the page shows; a refusal is its refusal.
        local document, refusal = printer(session, input.id)
        if not document then return refusal end

        local key = ('%s:%s:%d'):format(session.discordId, input.kind, input.id)
        if printing[key] then return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'in_progress' }) end
        printing[key] = true

        local ok, result = pcall(function()
            local agency = FredPD.Core.agencies.get(session.agencyId)
            local body, cut = service.bounded(document.body, service.PAPER_TEXT_LIMIT)

            local printed = {
                title = document.title,
                fields = document.fields,
                body = body,
                cut = cut,
                classification = document.classification or 'internal',
                agency = agency and agency.name or session.agencyId,
                printedAt = os.date('%Y-%m-%d %H:%M'),
                printedBy = session.callsign,
            }

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

                return { id = row.id, number = row.number }
            end

            -- A PDF, from the gateway.
            local gateway = FredPD.Bridge.gateway.service
            if not gateway.isEnabled() then
                repo.remove(row.id, session.agencyId)
                return route.refuse(FredPD.ErrorCode.CONFLICT, { copy = 'gateway_off' })
            end

            local rendered, pdf = gateway.renderPdf({
                title = document.title,
                fields = document.fields,
                body = document.body,
                classification = FredPD.t('records.classification.' .. printed.classification),
                letterhead = printed.agency,
                documentNumber = row.number,
                pageLabel = FredPD.t('document.pdf.page'),
                printedLabel = FredPD.t('document.pdf.printed', { at = printed.printedAt, by = session.callsign or '' }),
            })

            if not rendered or type(pdf.mediaRef) ~= 'string' then
                repo.remove(row.id, session.agencyId)
                return route.refuse(FredPD.ErrorCode.CONFLICT, { copy = 'gateway_unavailable' })
            end

            repo.setMedia(row.id, session.agencyId, pdf.mediaRef)

            return { id = row.id, number = row.number, url = gateway.downloadUrl(pdf.mediaRef, false) }
        end)

        printing[key] = nil
        if not ok then error(result) end

        return result
    end,
})
