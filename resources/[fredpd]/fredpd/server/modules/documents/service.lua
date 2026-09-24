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

--- A deep copy of an editor document, so cutting the paper copy never cuts
--- the document the caller goes on to use (the PDF carries all of it).
local function deepCopy(value, depth)
    if type(value) ~= 'table' or (depth or 0) > 32 then return value end

    local copy = {}
    for key, item in pairs(value) do copy[key] = deepCopy(item, (depth or 0) + 1) end
    return copy
end

--- The first `count` characters of `text`, never splitting a UTF-8 sequence.
--- Text that is not valid UTF-8 is cut by bytes, at the last byte that does
--- not start or continue a sequence.
local function firstChars(text, count)
    if count <= 0 then return '' end

    local ok, stop = pcall(utf8.offset, text, count + 1)
    if ok and stop then return text:sub(1, stop - 1) end
    if ok then return text end

    local cut = text:sub(1, count)
    return (cut:gsub('[\192-\255][\128-\191]*$', ''))
end

--- Characters, not bytes: Swedish text is two bytes a letter in places.
local function charCount(text)
    return utf8.len(text) or #text
end

--- A copy of `doc` holding at most `limit` characters of text. Everything
--- past the limit is dropped and the last node that fits is marked `…`.
--- `doc` itself is left as it was.
---
--- @return table doc, boolean cut
function Documents.bounded(doc, limit)
    local copy = type(doc) == 'table' and deepCopy(doc) or { type = 'doc', content = {} }
    local used, cut = 0, false

    eachText(copy, function(node)
        local text = tostring(node.text or '')
        local length = charCount(text)

        if cut then
            node.text = ''
        elseif used + length > limit then
            node.text = firstChars(text, math.max(0, limit - used)) .. '…'
            cut = true
        end

        used = used + length
    end)

    return copy, cut
end

--- Which copies of a record may be made (ADR-020, amended).
---
--- A paper copy leaves the access domain: whoever holds the item reads it,
--- with no session, no clearance and no audit. So paper is only for a
--- record at or below `paperCeiling` (default `internal`), in no
--- compartment, not sealed, and not read through a break-glass grant. A
--- PDF of a restricted record is an export (11.1) and needs
--- `document.export.restricted`.
---
--- @param control table the record's own access control, as its read returned it
--- @param options table { paperCeiling, breakglass (boolean), mayExportRestricted (boolean) }
--- @return table { paper = true | reason, pdf = true | reason, restricted = boolean }
function Documents.copyRule(control, options)
    local access = FredPD.Modules.access
    options = options or {}

    if type(control) ~= 'table' or not access.isLevel(control.classification) then
        return { paper = 'unclassified', pdf = 'unclassified', restricted = true }
    end

    local restricted = access.isRestricted(control)
    local shape = access.control(control)
    local ceiling = access.clearanceRank(options.paperCeiling or 'internal') or access.clearanceRank('internal')

    local paper = true
    if shape.sealed or next(shape.compartments) ~= nil then
        paper = 'compartmented'
    elseif options.breakglass then
        paper = 'breakglass'
    elseif access.clearanceRank(shape.classification) > ceiling then
        paper = 'classified'
    end

    local pdf = true
    if restricted and not options.mayExportRestricted then pdf = 'export_restricted' end

    return { paper = paper, pdf = pdf, restricted = restricted }
end

--- A person as a printed page names them: "Doe, John (P-000431)".
function Documents.personLine(person)
    if type(person) ~= 'table' then return nil end

    local name = table.concat({ person.lastName or '', person.firstName or '' }, ', '):gsub('^, ', ''):gsub(', $', '')
    return person.personNumber and ('%s (%s)'):format(name, person.personNumber) or name
end

--- An epoch as a printed page shows it.
--- A time as a printed page shows it. Takes seconds or, as oxmysql hands a
--- bare DATETIME over, milliseconds; a number or its string; a fraction
--- (`UNIX_TIMESTAMP` of a `DATETIME(3)`) is dropped, because `os.date` in
--- Lua 5.4 refuses a float.
function Documents.moment(epoch)
    local value = tonumber(epoch)
    if not value or value <= 0 then return '' end

    if value > 1e11 then value = value / 1000 end

    return os.date('%Y-%m-%d %H:%M', math.floor(value))
end

--- Appendix D: `{AGENCY}-D{YY}-{######}`.
function Documents.numberPrefix(shortName, year)
    return ('%s-D%02d-'):format(tostring(shortName):upper(), year % 100), 6
end

FredPD.Modules.documents = Documents

return Documents
