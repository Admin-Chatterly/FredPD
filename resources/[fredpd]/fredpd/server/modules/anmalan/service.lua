--- Anmälan och förundersökning: the logic (spec 7.7, 7.8).
---
--- Pure: no natives, no database, no locale lookups, so busted exercises it
--- outside FXServer (`spec/anmalan_spec.lua`).
---
--- Two state machines live here, and they are separate on purpose.
---
---   * **The anmälan workflow** -- utkast, inlämnad, återsänd, godkänd -- is an
---     *administrative* process inside the department. A supervisor approves;
---     approval locks.
---   * **The förundersökning lifecycle** -- inledd, slutdelgiven, redovisad,
---     nedlagd -- is a *legal* one. It is opened by a decision, led by a
---     förundersökningsledare who may be an åklagare, and ended by a decision.
---
--- Merging them would make a supervisor's approval and a prosecutor's decision
--- to drop a case the same transition, which is why 0009 gives them separate
--- tables and why this file gives them separate transition maps.
---
--- The rule worth reading first is `canApprove`. Everything else here is
--- bookkeeping; that one is the control.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Anmalan = {}

-- -----------------------------------------------------------------------------
-- Allowlists (mirroring 0009's CHECK constraints)
-- -----------------------------------------------------------------------------

--- The anmälan statuses, in the order a report moves through them.
local STATUSES <const> = { 'utkast', 'inlamnad', 'atersand', 'godkand' }

local IS_STATUS <const> = {}
for index = 1, #STATUSES do IS_STATUS[STATUSES[index]] = true end

--- The roles a person may hold on an anmälan.
---
--- Not a translation of the US set. `malsagande` is the injured party and
--- carries rights a "victim" does not have -- to be heard, and to bring a claim
--- alongside the prosecution -- so it is a role with legal consequence rather
--- than a label. `anmalare` is whoever reported it, which is very often the
--- same person in a second role, which is why 0009's primary key carries the
--- role.
local ROLLER <const> = { 'misstankt', 'malsagande', 'vittne', 'anmalare', 'annan' }

local IS_ROLL <const> = {}
for index = 1, #ROLLER do IS_ROLL[ROLLER[index]] = true end

--- How far a charge got (BrB 23).
local STAGES <const> = { 'fullbordat', 'forsok', 'forberedelse', 'stampling' }

local IS_STAGE <const> = {}
for index = 1, #STAGES do IS_STAGE[STAGES[index]] = true end

--- The förundersökning statuses.
local FU_STATUSES <const> = { 'inledd', 'slutdelgiven', 'redovisad', 'nedlagd' }

local IS_FU_STATUS <const> = {}
for index = 1, #FU_STATUSES do IS_FU_STATUS[FU_STATUSES[index]] = true end

function Anmalan.isStatus(value) return IS_STATUS[value] == true end
function Anmalan.isRoll(value) return IS_ROLL[value] == true end
function Anmalan.isStage(value) return IS_STAGE[value] == true end
function Anmalan.isFuStatus(value) return IS_FU_STATUS[value] == true end

function Anmalan.statuses()
    local out = {}
    for index = 1, #STATUSES do out[index] = STATUSES[index] end
    return out
end

function Anmalan.roller()
    local out = {}
    for index = 1, #ROLLER do out[index] = ROLLER[index] end
    return out
end

-- -----------------------------------------------------------------------------
-- The anmälan workflow (7.7)
-- -----------------------------------------------------------------------------

--- Which transitions exist, by the action that makes them.
---
--- Read as: from this status, this action lands on that status. Anything not in
--- the table is not a transition, which is what makes `godkand` terminal --
--- there is no row for it, so nothing moves an approved anmälan anywhere.
---
--- `atersand -> inlamnad` is the resubmission, and it is the same `submit`
--- action as the first one: an author who fixes what the supervisor asked for
--- does the same thing they did the first time, and a separate `resubmit`
--- action would be a second code path doing one job.
local TRANSITIONS <const> = {
    submit  = { utkast = 'inlamnad', atersand = 'inlamnad' },
    ['return'] = { inlamnad = 'atersand' },
    approve = { inlamnad = 'godkand' },
}

--- The status an action lands on, or nil when the action is not available here.
---
--- @param status string the current status
--- @param action string 'submit', 'return' or 'approve'
--- @return string|nil
function Anmalan.nextStatus(status, action)
    local row = TRANSITIONS[action]
    if not row then return nil end

    return row[status]
end

--- Is this anmälan locked against editing (7.7)?
---
--- Approved is locked, and that is the whole rule. An inlämnad one is *not*
--- locked here: it is held by `canEdit` below, which is about who rather than
--- about what, and keeping the two apart means "locked" keeps meaning the one
--- thing 7.7 uses it for -- a record that no longer changes, only gains
--- tilläggsuppgifter.
function Anmalan.isLocked(row)
    return type(row) == 'table' and row.status == 'godkand'
end

--- May this session edit the body of this anmälan?
---
--- Three conditions, and the order is the order they are worth checking in:
---
---   1. Not locked. An approved anmälan is amended by a tilläggsuppgift, never
---      in place.
---   2. It is a draft or it came back. An anmälan sitting in `inlamnad` is on a
---      supervisor's desk, and an author who could keep typing into it would be
---      changing the thing being reviewed while it is being reviewed.
---   3. The editor is the author, or holds the supervisor grant. `editAny` is
---      passed in rather than read from a session here, because this file holds
---      no session logic -- the route resolves the permission and hands over
---      the answer.
---
--- @param row table the anmälan
--- @param discordId string who is asking
--- @param editAny boolean whether they hold the department-wide edit grant
--- @return boolean
--- @return string|nil why not
function Anmalan.canEdit(row, discordId, editAny)
    if type(row) ~= 'table' then return false, 'not_found' end

    if Anmalan.isLocked(row) then return false, 'locked' end

    if row.status ~= 'utkast' and row.status ~= 'atersand' then
        return false, 'under_review'
    end

    if row.createdBy ~= discordId and not editAny then
        return false, 'not_author'
    end

    return true
end

--- May this session approve or return this anmälan?
---
--- **The rule this module exists to hold.** An officer may not approve their
--- own anmälan, whatever permissions they hold.
---
--- 7.7 asks for supervisor approval, and a department where the supervisor is
--- also the author of half the reports is the ordinary case on a small server
--- rather than an edge one -- so this is not a theoretical separation. The
--- whole value of an approval step is that a second person looked; an approval
--- an author can grant themselves records that nobody did, and it records it in
--- a field that will later be read as though somebody had.
---
--- Deliberately not overridable by a permission. There is no
--- `rms.anmalan.approve.own` and there should not be one: a grant that lets the
--- check be skipped is a grant that will be given to the one person who most
--- wants it.
---
--- @param row table the anmälan
--- @param discordId string who is asking
--- @param hasApprovePerm boolean whether they hold `rms.anmalan.approve`
--- @return boolean
--- @return string|nil why not
function Anmalan.canApprove(row, discordId, hasApprovePerm)
    if type(row) ~= 'table' then return false, 'not_found' end

    if not hasApprovePerm then return false, 'forbidden' end

    if row.status ~= 'inlamnad' then return false, 'not_submitted' end

    if row.createdBy == discordId then return false, 'own_report' end

    return true
end

--- May this session submit this anmälan for approval?
---
--- The author, or anybody holding the department-wide edit grant -- the same
--- test as editing, because submitting is the last edit.
function Anmalan.canSubmit(row, discordId, editAny)
    if type(row) ~= 'table' then return false, 'not_found' end

    if not Anmalan.nextStatus(row.status, 'submit') then
        return false, row.status == 'godkand' and 'locked' or 'not_submittable'
    end

    if row.createdBy ~= discordId and not editAny then
        return false, 'not_author'
    end

    return true
end

-- -----------------------------------------------------------------------------
-- Tilläggsuppgifter (7.7: "changes only through a supplemental")
-- -----------------------------------------------------------------------------

--- How deep a chain of tilläggsuppgifter may go.
---
--- Not a technical limit -- it is what stops `parentIsAllowed` walking a long
--- chain on every write, and a supplement to a supplement to a supplement is
--- already a record nobody can read in order.
Anmalan.MAX_CHAIN = 10

--- May this anmälan hang off that parent?
---
--- The cycle check the schema cannot hold. MariaDB refuses
--- `CHECK (parent_id <> id)` because `id` is AUTO_INCREMENT, and a longer cycle
--- is not expressible in a CHECK at all (0009 says so where the constraint
--- would have been), so this is the only place the rule exists.
---
--- Walks up from the proposed parent. If the chain reaches the child, adding
--- the link would close a cycle -- and a cycle here is not a cosmetic problem:
--- every read of the chain, every version snapshot and every print walks it,
--- and each of those would run until something ran out.
---
--- @param childId number|nil the row being parented, nil when it is new
--- @param parentId number the proposed parent
--- @param parentOf function(id) -> number|nil the parent of a given row
--- @return boolean
--- @return string|nil why not
function Anmalan.parentIsAllowed(childId, parentId, parentOf)
    if type(parentId) ~= 'number' then return false, 'invalid' end

    if childId and parentId == childId then return false, 'self_parent' end

    local seen = {}
    local current = parentId
    local depth = 0

    while current do
        if childId and current == childId then return false, 'cycle' end

        -- A cycle that does not pass through the child at all means the data is
        -- already broken. Refusing is better than walking it forever.
        if seen[current] then return false, 'cycle' end
        seen[current] = true

        depth = depth + 1
        if depth > Anmalan.MAX_CHAIN then return false, 'too_deep' end

        current = parentOf(current)
    end

    return true
end

-- -----------------------------------------------------------------------------
-- Charges
-- -----------------------------------------------------------------------------

--- Is this stage available for this catalogue row (BrB 23)?
---
--- Försök, förberedelse and stämpling are punishable only where the statute
--- says so, which is why 0008 stores `forsok` and `forberedelse` per offence
--- rather than deriving them. A charging screen that offered "försök till" on
--- an offence where it does not exist would produce a charge that cannot be
--- filed, and the officer would not find out until a prosecutor told them.
---
--- Stämpling rides on `forberedelse`: brottsbalken names them together in the
--- same paragraf of each kapitel, and no offence in the catalogue has one
--- without the other.
---
--- @param brottRow table a catalogue row from the brott module
--- @param stage string
--- @return boolean
function Anmalan.stageIsAvailable(brottRow, stage)
    if type(brottRow) ~= 'table' or not IS_STAGE[stage] then return false end

    if stage == 'fullbordat' then return true end

    local forsok = brottRow.forsok == true or brottRow.forsok == 1
    local forberedelse = brottRow.forberedelse == true or brottRow.forberedelse == 1

    if stage == 'forsok' then return forsok end

    return forberedelse
end

--- Splits a charge list into the counts that name a person and the ones that do
--- not, keeping the order within each.
---
--- The charging screen shows charges grouped by misstänkt, with the ones
--- against nobody in particular underneath -- which is the ordinary case, not
--- an incomplete record: most anmälningar are written with no suspect.
---
--- @param charges table rows from `fpd_anmalan_brott`
--- @return table byPerson  { [personId] = { charge, … } }
--- @return table unattributed
function Anmalan.groupCharges(charges)
    local byPerson, unattributed = {}, {}

    if type(charges) ~= 'table' then return byPerson, unattributed end

    for index = 1, #charges do
        local charge = charges[index]
        local personId = charge and charge.personId

        if personId then
            byPerson[personId] = byPerson[personId] or {}
            local bucket = byPerson[personId]
            bucket[#bucket + 1] = charge
        elseif charge then
            unattributed[#unattributed + 1] = charge
        end
    end

    return byPerson, unattributed
end

-- -----------------------------------------------------------------------------
-- The förundersökning lifecycle (7.8)
-- -----------------------------------------------------------------------------

--- Which FU transitions exist.
---
--- Two endings, and they are not the same ending. **Nedläggning** is a decision
--- that the investigation stops -- brott kan ej styrkas, spaningsuppslag
--- saknas. **Redovisning** is handing the finished investigation to the
--- åklagare, and it follows slutdelgivning (RB 23:18a), where the misstänkt and
--- their försvarare are given the material and a chance to respond.
---
--- An FU may be lagd ned from either state: material can turn out not to hold
--- up after slutdelgivning too.
local FU_TRANSITIONS <const> = {
    slutdelge = { inledd = 'slutdelgiven' },
    redovisa  = { slutdelgiven = 'redovisad' },
    lagg_ned  = { inledd = 'nedlagd', slutdelgiven = 'nedlagd' },
}

--- The FU status an action lands on, or nil when it is not available.
function Anmalan.nextFuStatus(status, action)
    local row = FU_TRANSITIONS[action]
    if not row then return nil end

    return row[status]
end

--- Is an FU still running?
function Anmalan.fuIsOpen(row)
    if type(row) ~= 'table' then return false end

    return row.status == 'inledd' or row.status == 'slutdelgiven'
end

--- May this session take a decision in this förundersökning?
---
--- The FU-ledare, or somebody holding the department-wide grant. Not "anyone
--- with the permission": RB gives the decisions to the person leading the
--- investigation, and an FU with a named ledare whose decisions are taken by
--- somebody else is an FU whose record says the wrong name.
---
--- `ledAny` exists for the supervisor who has to reassign an investigation
--- whose ledare has left, which is otherwise unreachable.
---
--- @param row table the FU
--- @param discordId string
--- @param ledAny boolean
--- @return boolean
--- @return string|nil
function Anmalan.canDecide(row, discordId, ledAny)
    if type(row) ~= 'table' then return false, 'not_found' end

    if not Anmalan.fuIsOpen(row) then return false, 'fu_closed' end

    if row.fuLedare ~= discordId and not ledAny then return false, 'not_ledare' end

    return true
end

--- Does this FU require an åklagare as its ledare?
---
--- RB 23:3: the prosecutor leads once a person is skäligen misstänkt for
--- anything but the simplest offences. FredPD cannot judge "skäligen
--- misstänkt", so the test it can apply is the one that follows from the
--- catalogue: an FU carrying a charge whose ceiling reaches the threshold is
--- one a police FU-ledare should not be leading alone.
---
--- Advisory rather than enforced -- it colours a field on the screen and does
--- not refuse a decision. An automatic rule that blocked a police FU-ledare
--- from their own investigation on the strength of a straffskala would be
--- wrong more often than it was right, and wrong in the direction that stops
--- work.
---
--- @param skalor table straffskalor from `Brott.straffskala`
--- @return boolean
function Anmalan.aklagareIndicated(skalor)
    if type(skalor) ~= 'table' then return false end

    for index = 1, #skalor do
        local skala = skalor[index]

        -- Livstid, or a ceiling from two years up. Two years is where the
        -- ordinary police-led förundersökning stops being the usual shape.
        if skala and (skala.max == nil or skala.max >= 24) then return true end
    end

    return false
end

--- The dispositions after which a call needs a report (7.7): somebody was
--- arrested or fined, or the officer said a report was taken. A call cleared
--- as unfounded or gone on arrival does not.
local NEEDS_REPORT <const> = {
    report_taken = true, arrest_made = true, citation_issued = true,
}

function Anmalan.dispositionNeedsReport(disposition)
    return NEEDS_REPORT[disposition] == true
end

--- The highest of several classifications, by `rank` (the access module's
--- `clearanceRank`): a record started from others is filed no lower than
--- any of them (4.5). Unknown or missing levels are ignored; none at all
--- is `internal`, the default every record starts at.
function Anmalan.highestClassification(levels, rank)
    local best, bestRank = 'internal', rank('internal') or 0

    for index = 1, #(levels or {}) do
        local level = levels[index]
        local value = level and rank(level)

        if value and value > bestRank then best, bestRank = level, value end
    end

    return best
end

--- An anmälan that can still take another person or charge: not yet sent
--- for review, or sent back.
function Anmalan.isEditable(status)
    return status == 'utkast' or status == 'atersand'
end

FredPD.Modules.anmalan = Anmalan

return Anmalan
