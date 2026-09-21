--- Surveillance: the secret coercive measures (spec 9, RB 27:18, 27:20d).
---
--- Pure: no natives, no database, no locale lookups, so busted exercises it
--- outside FXServer (`spec/surveillance_spec.lua`).
---
--- **This is the tingsrätt-decided half of what 0011's header calls "where RB
--- actually requires a court".** Husrannsakan and kroppsvisitation are decided
--- by the förundersökningsledare; HAK, HRA, spårsändare and kameraövervakning
--- reach somebody who does not know they are watched and cannot object before
--- the fact, and RB gives that decision to a judge alone. So this module's
--- shape mirrors `frihet/service.lua`'s chain -- a capacity that may only
--- *request*, a different capacity that alone may *decide* -- rather than
--- `tvangsmedel/service.lua`'s single-step `mayDecide`.
---
--- `isValid` is the function that matters for the same reason `Tvang.isValid`
--- does: spec 14 exposes `HasActiveWarrant(target, kind, method?)` to other
--- resources, and every way of being invalid is its own named return so the
--- caller can say why rather than merely that.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Surveillance = {}

-- -----------------------------------------------------------------------------
-- Allowlists (mirroring 0015's CHECK constraints)
-- -----------------------------------------------------------------------------

local TARGETS <const> = { 'person', 'phone', 'vehicle', 'location' }

local IS_TARGET <const> = {}
for index = 1, #TARGETS do IS_TARGET[TARGETS[index]] = true end

function Surveillance.isTarget(value) return IS_TARGET[value] == true end

--- The secret measures. Swedish names for the two RB gives, and two FredPD
--- adds under the same tingsrätt gate:
---
---   * **hak** (hemlig avlyssning av elektronisk kommunikation, RB 27:18) --
---     live listening to a warranted number's calls.
---   * **hra** (hemlig rumsavlyssning, RB 27:20d) -- a listening device in a
---     place.
---   * **sparsandare** -- a tracker, position pings to authorized sessions.
---   * **kameraovervakning** -- a camera on a place.
local METHODS <const> = { 'hak', 'hra', 'sparsandare', 'kameraovervakning' }

local IS_METHOD <const> = {}
for index = 1, #METHODS do IS_METHOD[METHODS[index]] = true end

function Surveillance.isMethod(value) return IS_METHOD[value] == true end

function Surveillance.methods()
    local out = {}
    for index = 1, #METHODS do out[index] = METHODS[index] end
    return out
end

local STATUSES <const> = { 'begard', 'beviljad', 'avslagen', 'upphavd' }

local IS_STATUS <const> = {}
for index = 1, #STATUSES do IS_STATUS[STATUSES[index]] = true end

function Surveillance.isStatus(value) return IS_STATUS[value] == true end

--- Why a request or a revocation is made, as a locale key (invariant 6).
---
--- The NUI renders this with `t()`, which prints an unknown key verbatim on
--- the face of a register a domare reads before deciding whether to watch
--- somebody -- the same reasoning `Tvang.isTvangGrund` gives for coercive
--- measures generally.
local GRUNDER <const> = {
    'skalig_misstanke', 'sarskild_vikt', 'fara_i_drojsmal',
    'grov_brottslighet', 'annan',
}

local IS_GRUND <const> = {}
for index = 1, #GRUNDER do IS_GRUND[GRUNDER[index]] = true end

function Surveillance.isGrund(value) return IS_GRUND[value] == true end

--- Is this a locale key an intercept's `kind` may carry?
---
--- The same reasoning `Frihet.isLogKind` argues at length: what a captured
--- interception actually *is* -- a call, a message, a position ping, a still
--- from a camera -- is a matter of which methods a department has built out
--- rather than of what RB names, so this is a key and not an enum. What it
--- must not be is a free string: the NUI renders it with `t()`, which prints
--- an unknown key verbatim, so an unshaped 64-character field would let an
--- observer write an arbitrary sentence into a capture and have it drawn as a
--- label, in both locales. The prefix is the whole check, and it keeps the
--- freedom the comment wanted -- a department adds
--- `surveillance.intercept.doorbell` to its locale overlay and the server
--- accepts it without a schema change.
local INTERCEPT_KIND_PATTERN <const> = '^surveillance%.intercept%.[a-z][a-z0-9_]*$'

function Surveillance.isInterceptKind(value)
    return type(value) == 'string' and value:match(INTERCEPT_KIND_PATTERN) ~= nil
end

--- Why a granted measure was revoked before its window ran out (RB 27:23).
local UPPHAVANDEGRUNDER <const> = { 'skal_upphorda', 'syfte_uppnatt', 'annan' }

local IS_UPPHAVANDEGRUND <const> = {}
for index = 1, #UPPHAVANDEGRUNDER do IS_UPPHAVANDEGRUND[UPPHAVANDEGRUNDER[index]] = true end

function Surveillance.isUpphavandegrund(value) return IS_UPPHAVANDEGRUND[value] == true end

-- -----------------------------------------------------------------------------
-- Who may take each decision
-- -----------------------------------------------------------------------------

--- How long a grant runs for, by default, in seconds.
---
--- Not a statutory figure. A month is long enough for an investigation to act
--- on and short enough that a forgotten grant lapses rather than becoming a
--- standing authority to listen -- the same reasoning `Tvang.DEFAULT_VALIDITY`
--- gives, at a longer figure because these are RB's most deliberated
--- decisions and are not requested lightly.
Surveillance.DEFAULT_VALIDITY = 30 * 24 * 3600

--- May this capacity request a secret measure?
---
--- Only the åklagare. Unlike `Tvang.mayDecide`, which asks whether a capacity
--- may *decide* something, this asks only whether it may *apply* -- the
--- decision itself is `mayGrant`'s question, and only a domare ever answers it.
function Surveillance.mayRequest(capacity)
    return capacity == 'aklagare'
end

--- May this capacity grant or refuse one?
function Surveillance.mayGrant(capacity)
    return capacity == 'domare'
end

--- May this capacity revoke a granted one early (RB 27:23)?
---
--- Either decision-maker: the åklagare who no longer needs it, or the domare
--- who granted it, may end it. A patrol officer never can -- ending an
--- interception is as much a legal act as starting one.
function Surveillance.mayUpphav(capacity)
    return capacity == 'aklagare' or capacity == 'domare'
end

-- -----------------------------------------------------------------------------
-- Validity -- what spec 14's export answers
-- -----------------------------------------------------------------------------

--- Is this measure live right now?
---
--- Every way of being invalid is its own named return, the same discipline
--- `Tvang.isValid` uses and for the same reason: the caller matters (spec 14's
--- `HasActiveWarrant`), and "false" alone tells nobody why.
---
--- @param row table the measure
--- @param now number epoch seconds
--- @return boolean
--- @return string|nil why not
function Surveillance.isValid(row, now)
    if type(row) ~= 'table' then return false, 'not_found' end

    if row.status ~= 'beviljad' then return false, row.status or 'not_found' end

    -- Revocation overrides the window, whatever it said.
    if row.upphavdAt then return false, 'upphavd' end

    if row.validFrom and now < row.validFrom then return false, 'not_yet' end

    if row.validUntil and now > row.validUntil then return false, 'expired' end

    return true
end

--- The first live measure for a target and method, out of a list.
---
--- Mirrors `Tvang.firstValid`. Returns the row rather than a boolean so the
--- caller can name *which* decision authorised what it did.
---
--- @param method string|nil when given, only that method counts
--- @return table|nil
function Surveillance.firstValid(rows, now, method)
    if type(rows) ~= 'table' then return nil end

    for index = 1, #rows do
        local row = rows[index]

        if (not method or row.method == method) and Surveillance.isValid(row, now) then
            return row
        end
    end

    return nil
end

--- Does this measure need renewing soon?
---
--- Warns inside the last day of a live grant's window, so an observer is told
--- before a session goes dark rather than discovering it when the next call
--- fails.
function Surveillance.needsRenewal(row, now)
    local live = Surveillance.isValid(row, now)
    if not live or not row.validUntil then return false end

    return (row.validUntil - now) <= (24 * 3600)
end

--- How this measure should be shown, in one word the NUI renders with `t()`.
---
--- Mirrors `Spaning.bannerFor`'s reasoning, at a fixed level: unlike a
--- lookout's priority, a secret measure has no "how loud" dial -- it is either
--- live (`active`), awaiting a decision (`pending`), or neither (`closed`).
function Surveillance.bannerFor(row, now)
    if type(row) ~= 'table' then return 'closed' end
    if row.status == 'begard' then return 'pending' end

    local live = Surveillance.isValid(row, now)
    return live and 'active' or 'closed'
end

-- -----------------------------------------------------------------------------
-- Validation
-- -----------------------------------------------------------------------------

--- Checks a request a route is about to write.
---
--- @return string|nil code
--- @return table|nil fields
function Surveillance.validateRequest(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if type(input.fuId) ~= 'number' or input.fuId < 1 then
        return 'invalid', { fuId = 'required' }
    end

    if not Surveillance.isTarget(input.targetKind) then
        return 'invalid', { targetKind = 'unknown' }
    end

    local hasTarget = type(input.targetId) == 'number' and input.targetId >= 1
    local hasLabel = type(input.targetLabel) == 'string'
        and input.targetLabel:gsub('%s', '') ~= ''

    -- A target has to be something FredPD holds or a label naming what it does
    -- not, the same rule `Spaning.validate` gives `description`.
    if not hasTarget and not hasLabel then
        return 'invalid', { targetLabel = 'required_without_target' }
    end

    -- A telephone number or a room is not a foreign key into anything this
    -- suite holds, so those kinds may only carry a label.
    if (input.targetKind == 'phone' or input.targetKind == 'location') and hasTarget then
        return 'invalid', { targetId = 'not_allowed' }
    end

    if not Surveillance.isMethod(input.method) then
        return 'invalid', { method = 'unknown' }
    end

    if type(input.grund) ~= 'string' or input.grund == '' then
        return 'invalid', { grund = 'required' }
    end

    if not Surveillance.isGrund(input.grund) then
        return 'invalid', { grund = 'not_a_key' }
    end

    return nil
end

FredPD.Modules.surveillance = Surveillance

return Surveillance
