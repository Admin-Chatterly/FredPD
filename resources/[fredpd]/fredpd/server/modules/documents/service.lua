--- Printed documents (spec 7.28, ADR-020): the pure part, and the registry of
--- what can be printed.
---
--- Each module that owns a printable record registers a *printer* for it
--- here: a function that reads the record through that module's own access
--- check and says what the printed page shows. The documents module never
--- reaches into another module's tables; it asks the owner.
---
--- No natives, no database (`spec/documents_spec.lua`).

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Documents = {}

--- kind -> printer(session, id) -> document | nil, refusal
local printers = {}

--- Registered at load by the module that owns the record.
---
--- @param kind string one of `ck_fpd_documents_kind`
--- @param printer fun(session: table, id: number): table|nil, table|nil
function Documents.register(kind, printer)
    printers[kind] = printer
end

function Documents.printerFor(kind)
    return printers[kind]
end

--- How much text a paper copy carries. The whole document travels in the
--- inventory item's metadata, which the inventory stores and syncs; a
--- narrative longer than this is cut, with the cut marked, and the full
--- record is one query away for anybody allowed to read it.
Documents.PAPER_TEXT_LIMIT = 6000

--- Plain text to an editor document of paragraphs (invariant 10: a document
--- is editor JSON, never HTML).
function Documents.textToDoc(text)
    local content = {}

    for block in tostring(text or ''):gsub('\r\n', '\n'):gmatch('[^\n]+') do
        local trimmed = block:match('^%s*(.-)%s*$')
        if trimmed ~= '' then
            content[#content + 1] = { type = 'paragraph', content = { { type = 'text', text = trimmed } } }
        end
    end

    return { type = 'doc', content = content }
end

--- The text nodes a document may hold, in order, for counting and cutting.
local function eachText(node, visit)
    if type(node) ~= 'table' then return end
    if node.type == 'text' then visit(node) end

    for _, child in ipairs(type(node.content) == 'table' and node.content or {}) do
        eachText(child, visit)
    end
end

--- A copy of `doc` holding at most `limit` characters of text. Everything
--- past the limit is dropped and the last node that fits is marked `…`.
---
--- @return table doc, boolean cut
function Documents.bounded(doc, limit)
    local copy = type(doc) == 'table' and doc or { type = 'doc', content = {} }
    local used, cut = 0, false

    eachText(copy, function(node)
        local text = tostring(node.text or '')

        if cut then
            node.text = ''
        elseif used + #text > limit then
            node.text = text:sub(1, math.max(0, limit - used)) .. '…'
            cut = true
        end

        used = used + #text
    end)

    return copy, cut
end

--- A person as a printed page names them: "Doe, John (P-000431)".
function Documents.personLine(person)
    if type(person) ~= 'table' then return nil end

    local name = table.concat({ person.lastName or '', person.firstName or '' }, ', '):gsub('^, ', ''):gsub(', $', '')
    return person.personNumber and ('%s (%s)'):format(name, person.personNumber) or name
end

--- An epoch as a printed page shows it.
function Documents.moment(epoch)
    if type(epoch) ~= 'number' then return '' end
    return os.date('%Y-%m-%d %H:%M', epoch)
end

--- Appendix D: `{AGENCY}-D{YY}-{######}`.
function Documents.numberPrefix(shortName, year)
    return ('%s-D%02d-'):format(tostring(shortName):upper(), year % 100), 6
end

FredPD.Modules.documents = Documents

return Documents
