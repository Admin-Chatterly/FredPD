--- Intelligence logic (spec 10).
---
--- The rules PD-Span kept in Postgres triggers and functions, moved here where
--- busted can test them: write-time normalisation, the undirected-pair ordering
--- that stops an association being stored twice, search scoring, and the merge
--- that folds a duplicate person into another.
---
--- Pure: no natives, no database.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Intel = {}

--- Sources whose identity is protected. A note from one of these hides its
--- source unless the reader holds `intel.source.view`.
---
--- PD-Span showed the source to everyone with an account. For an informant that
--- is the difference between a register and an exposure, and it is the single
--- largest gap the inventory found (spec 10.6).
local PROTECTED_SOURCES <const> = { informant = true, surveillance = true, wiretap = true }

local MAX_TAGS <const> = 12
local MAX_TAG_LENGTH <const> = 64

-- -----------------------------------------------------------------------------
-- Normalisation (PD-Span's `blank_to_null`, `normalize_plate`, `normalize_tags`)
-- -----------------------------------------------------------------------------

--- Trims, and turns an empty string into nil.
---
--- An empty text field and an absent one mean the same thing to an officer, and
--- storing both makes every later query check for two things.
function Intel.blankToNull(value)
    if type(value) ~= 'string' then return nil end

    local trimmed = value:gsub('^%s*(.-)%s*$', '%1')
    if trimmed == '' then return nil end

    return trimmed
end

--- Plates are stored upper-case with the inner whitespace removed, so that
--- `abc 123` and `ABC123` are the same plate when someone searches for one.
function Intel.normalizePlate(value)
    local plate = Intel.blankToNull(value)
    if not plate then return nil end

    return (plate:upper():gsub('%s+', ''))
end

--- Tags: trimmed, lower-cased, de-duplicated, order preserved.
---
--- Lower-casing matters more than it looks: the tag bar groups by exact value,
--- so `Narkotika` and `narkotika` would otherwise be two different filters that
--- each hold half the intelligence.
function Intel.normalizeTags(list)
    if type(list) ~= 'table' then return {} end

    local seen, out = {}, {}

    for index = 1, #list do
        local tag = Intel.blankToNull(list[index])

        if tag then
            tag = tag:lower():sub(1, MAX_TAG_LENGTH)

            if not seen[tag] and #out < MAX_TAGS then
                seen[tag] = true
                out[#out + 1] = tag
            end
        end
    end

    return out
end

-- -----------------------------------------------------------------------------
-- Associations
-- -----------------------------------------------------------------------------

--- Orders a pair so an undirected association has exactly one representation.
---
--- The table's CHECK enforces `person_id < associate_id`; this is what makes
--- callers satisfy it. Without it, A-B and B-A would both insert and the link
--- chart would draw two edges for one relationship.
---
--- @return number|nil low, number|nil high, string|nil error
function Intel.orderPair(a, b)
    if type(a) ~= 'number' or type(b) ~= 'number' then return nil, nil, 'type' end
    if a == b then return nil, nil, 'self' end

    if a < b then return a, b end
    return b, a
end

-- -----------------------------------------------------------------------------
-- Reading
-- -----------------------------------------------------------------------------

--- The name to show for a person, or nil when there is none.
---
--- PD-Span generated the string "Okänd" in the database. A label belongs in the
--- locale files (invariant 6), so this returns nil and the interface renders
--- `intel.person.unknown` itself.
function Intel.displayName(person)
    if not person then return nil end

    return Intel.blankToNull(person.name) or Intel.blankToNull(person.alias)
end

--- Hides the source of a note when the reader is not cleared to see it.
---
--- The note itself stays readable -- withholding the intelligence would defeat
--- the point of a shared register. What is withheld is *where it came from*,
--- which is the part that identifies a person who talked to the police.
---
--- @param note table
--- @param canSeeSource boolean
--- @return table the note, safe to send
function Intel.redactSource(note, canSeeSource)
    if canSeeSource or not note.source or not PROTECTED_SOURCES[note.source] then
        return note
    end

    local safe = {}
    for key, value in pairs(note) do safe[key] = value end

    safe.source = nil
    safe.sourceProtected = true

    return safe
end

--- True when a source is one whose identity is protected.
function Intel.isProtectedSource(source)
    return source ~= nil and PROTECTED_SOURCES[source] == true
end

-- -----------------------------------------------------------------------------
-- Search
-- -----------------------------------------------------------------------------

--- Scores a match, mirroring what PD-Span's `search_all` ranked by.
---
--- The trigram similarity that gave it typo tolerance has no MariaDB
--- equivalent, so this is the substring half only: an exact hit outranks a
--- prefix, which outranks a match anywhere. Good enough to put the obvious
--- answer first, which is what the ranking is for.
---
--- @param haystack string|nil already lower-cased
--- @param needle string already lower-cased and trimmed
--- @return number 0 when there is no match
function Intel.score(haystack, needle)
    if type(haystack) ~= 'string' or needle == '' then return 0 end

    if haystack == needle then return 1.0 end
    if haystack:sub(1, #needle) == needle then return 0.8 end
    if haystack:find(needle, 1, true) then return 0.6 end

    return 0
end

--- Prepares a search term: trimmed, lower-cased, nil when too short to be useful.
---
--- One character matches most of the register and costs a full scan, so it is
--- refused rather than answered badly.
function Intel.searchTerm(value)
    local term = Intel.blankToNull(value)
    if not term or #term < 2 then return nil end

    return term:lower()
end

-- -----------------------------------------------------------------------------
-- Merging a duplicate person
-- -----------------------------------------------------------------------------

--- Works out the surviving record's fields when `drop` is folded into `keep`.
---
--- Follows PD-Span's `merge_people`: the kept record wins every field it has,
--- blanks are filled from the dropped one, descriptions are concatenated rather
--- than one being lost, and a kept status of `unknown` yields to a real one.
---
--- Pure, and separate from the SQL, because this is the part where a mistake
--- attributes one person's intelligence to another.
---
--- @return table|nil merged fields, string|nil error
function Intel.mergePlan(keep, drop)
    if not keep or not drop then return nil, 'not_found' end
    if keep.id == drop.id then return nil, 'same' end

    local description
    local keepDescription = Intel.blankToNull(keep.description)
    local dropDescription = Intel.blankToNull(drop.description)

    if keepDescription and dropDescription then
        description = keepDescription .. '\n\n' .. dropDescription
    else
        description = keepDescription or dropDescription
    end

    return {
        name = Intel.blankToNull(keep.name) or Intel.blankToNull(drop.name),
        alias = Intel.blankToNull(keep.alias) or Intel.blankToNull(drop.alias),
        description = description,
        photoPath = keep.photo_path or drop.photo_path,
        status = (keep.status == 'unknown') and drop.status or keep.status,
    }
end

-- -----------------------------------------------------------------------------
-- Validation beyond what the schema expresses
-- -----------------------------------------------------------------------------

--- A note must hang on something, or be a general tip with a body.
---
--- PD-Span allowed a note attached to nothing at all, deliberately: that is how
--- a tip is logged before anyone knows who it concerns. Kept.
function Intel.validateNote(input)
    if not Intel.blankToNull(input.body) then
        return 'invalid', { body = 'required' }
    end

    return nil
end

--- Evidence is either an upload or a link, never both and never neither.
function Intel.validateEvidence(input)
    local hasUrl = Intel.blankToNull(input.url) ~= nil
    local hasPath = Intel.blankToNull(input.storagePath) ~= nil

    if hasUrl == hasPath then
        return 'invalid', { url = 'file_or_url' }
    end

    if hasUrl then
        local url = input.url
        if not (url:match('^https?://[^%s]+$')) then
            return 'invalid', { url = 'not_http' }
        end
    end

    -- Must hang on at least one record, or it is an orphan nobody will find.
    if not input.personId and not input.orgId and not input.caseId then
        return 'invalid', { target = 'required' }
    end

    return nil
end

-- -----------------------------------------------------------------------------
-- The link diagram (PD-Span's /board, spec 10.6)
-- -----------------------------------------------------------------------------

--- How many people a board draws. Past this the diagram is unreadable, and
--- the reader is told it was cut rather than handed a hairball.
Intel.BOARD_PERSON_CAP = 300

--- A board from what the reader may see: nodes that survived the access
--- filter, and only the edges whose both ends did. An edge to a node that is
--- not on the board would point at something the reader cannot read -- which
--- is itself the thing access control exists to hide (4.5).
---
--- @param persons table rows the access filter kept (stubs already dropped)
--- @param orgs table rows the access filter kept
--- @param memberships table { personId, orgId, role, isConfirmed }
--- @param associates table { personId, associateId, relationship, isConfirmed }
--- @return table { persons, orgs, memberships, associates, truncated }
function Intel.boardGraph(persons, orgs, memberships, associates)
    local truncated = #persons > Intel.BOARD_PERSON_CAP
    local keptPersons, personIds, orgIds = {}, {}, {}

    for index = 1, math.min(#persons, Intel.BOARD_PERSON_CAP) do
        local person = persons[index]
        keptPersons[#keptPersons + 1] = {
            id = person.id, name = person.name, alias = person.alias, status = person.status,
        }
        personIds[person.id] = true
    end

    local keptOrgs = {}
    for _, org in ipairs(orgs) do
        keptOrgs[#keptOrgs + 1] = { id = org.id, name = org.name, type = org.type, status = org.status }
        orgIds[org.id] = true
    end

    local keptMemberships = {}
    for _, edge in ipairs(memberships) do
        if personIds[edge.personId] and orgIds[edge.orgId] then
            keptMemberships[#keptMemberships + 1] = {
                personId = edge.personId, orgId = edge.orgId, role = edge.role,
                isConfirmed = edge.isConfirmed == true or edge.isConfirmed == 1,
            }
        end
    end

    local keptAssociates = {}
    for _, edge in ipairs(associates) do
        if personIds[edge.personId] and personIds[edge.associateId] then
            keptAssociates[#keptAssociates + 1] = {
                personId = edge.personId, associateId = edge.associateId, relationship = edge.relationship,
                isConfirmed = edge.isConfirmed == true or edge.isConfirmed == 1,
            }
        end
    end

    return {
        persons = keptPersons,
        orgs = keptOrgs,
        memberships = keptMemberships,
        associates = keptAssociates,
        truncated = truncated,
    }
end

-- -----------------------------------------------------------------------------
-- What a reader may see of linked records (4.5)
-- -----------------------------------------------------------------------------

--- The records a list links to, once each, as rows the access filter can
--- judge: `{ id, classification }`. A row with no link in `idField` (a case
--- link to an organisation, asked about its person) names nothing.
---
--- @param rows table
--- @param idField string the linked record's id on each row
--- @param classificationField string its classification on each row
--- @return table
function Intel.linkedRecords(rows, idField, classificationField)
    local out, seen = {}, {}
    for _, row in ipairs(rows or {}) do
        local id = row[idField]
        if id ~= nil and not seen[id] then
            seen[id] = true
            out[#out + 1] = { id = id, classification = row[classificationField] }
        end
    end
    return out
end

--- The rows whose linked record the reader may read in full. A link to one
--- they may not -- or may see only as a stub -- is left off with no gap: the
--- link itself says who is tied to whom (4.5). Rows with no link in
--- `idField` stay; another pass judges their other end.
---
--- @param rows table
--- @param idField string
--- @param visible table set of readable ids
--- @return table
function Intel.keepLinked(rows, idField, visible)
    local out = {}
    for _, row in ipairs(rows or {}) do
        local id = row[idField]
        if id == nil or visible[id] then out[#out + 1] = row end
    end
    return out
end

--- Per parent, how many rows link to a readable record: the notes on a
--- person, the members of an organisation. Counted after the access check,
--- so a count never says there is more than the reader may open (4.5).
---
--- @param rows table
--- @param parentField string the parent's id on each row
--- @param idField string the linked record's id on each row
--- @param visible table set of readable ids
--- @param predicate function|nil counts only rows it accepts
--- @return table map parent id -> count
function Intel.countLinked(rows, parentField, idField, visible, predicate)
    local counts = {}
    for _, row in ipairs(rows or {}) do
        local parent, id = row[parentField], row[idField]
        if parent ~= nil and id ~= nil and visible[id] and (not predicate or predicate(row)) then
            counts[parent] = (counts[parent] or 0) + 1
        end
    end
    return counts
end

--- Per parent, the latest `timeField` among rows linking to a readable record.
--- @return table map parent id -> time
function Intel.latestLinked(rows, parentField, idField, visible, timeField)
    local latest = {}
    for _, row in ipairs(rows or {}) do
        local parent, at = row[parentField], row[timeField]
        if parent ~= nil and at ~= nil and visible[row[idField]] then
            if latest[parent] == nil or at > latest[parent] then latest[parent] = at end
        end
    end
    return latest
end

--- The parents of the readable rows, once each, in order: the people or
--- organisations a tag is on, counting only the notes the reader may read.
--- @return table list of parent ids
function Intel.parentsOf(rows, parentField, idField, visible)
    local out, seen = {}, {}
    for _, row in ipairs(rows or {}) do
        local parent = row[parentField]
        if parent ~= nil and visible[row[idField]] and not seen[parent] then
            seen[parent] = true
            out[#out + 1] = parent
        end
    end
    return out
end

--- Tag counts over the notes a reader may read, most used first, as
--- PD-Span's `distinct_tags()` ordered them.
---
--- @param uses table rows of `{ tag, id }` (one per tag on a note)
--- @param visible table set of readable note ids
--- @param limit number|nil
--- @return table list of `{ tag, uses }`
function Intel.tagCounts(uses, visible, limit)
    local counts = {}
    for _, use in ipairs(uses or {}) do
        if visible[use.id] and type(use.tag) == 'string' then
            counts[use.tag] = (counts[use.tag] or 0) + 1
        end
    end

    local out = {}
    for tag, count in pairs(counts) do out[#out + 1] = { tag = tag, uses = count } end
    table.sort(out, function(a, b)
        if a.uses ~= b.uses then return a.uses > b.uses end
        return a.tag < b.tag
    end)

    local cap = limit or 100
    for index = #out, cap + 1, -1 do out[index] = nil end
    return out
end

FredPD.Modules.intel = Intel
