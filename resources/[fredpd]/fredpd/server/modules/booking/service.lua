--- Inskrivning i arrest: cell assignment and the property inventory (spec
--- 7.9), where the gripande/anhållande/häktning chain in `frihet` stops.
---
--- Pure: no natives, no database, no locale lookups, so busted exercises it
--- outside FXServer (`spec/booking_spec.lua`).
---
--- **`isReleaseReason` is the function that matters.** `release_reason_key`
--- is a locale key the NUI renders with `t()`, and `t()` falls back to
--- printing an unknown key verbatim -- so a client that could send any string
--- here could have it drawn as a label, in English, in both locales. That is
--- exactly the defect review found in four other modules before this one:
--- each skipped the server-side allowlist check and trusted whatever key the
--- client had rendered from its own copy of the list, which is not a check at
--- all once the client is the thing being distrusted (invariant 1 and
--- invariant 6 together). The route validates `input.releaseReasonKey`
--- against this allowlist before it ever reaches SQL; it never trusts that
--- the NUI only ever sent one it recognised.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Booking = {}

-- -----------------------------------------------------------------------------
-- Release reasons (locale keys, invariant 6)
-- -----------------------------------------------------------------------------

local RELEASE_REASONS <const> = {
    'bail', 'released_no_charge', 'transferred', 'time_served', 'other',
}

local IS_RELEASE_REASON <const> = {}
for index = 1, #RELEASE_REASONS do IS_RELEASE_REASON[RELEASE_REASONS[index]] = true end

function Booking.isReleaseReason(value) return IS_RELEASE_REASON[value] == true end

-- -----------------------------------------------------------------------------
-- Validation
-- -----------------------------------------------------------------------------

--- Checks a booking (cell assignment) a route is about to write.
---
--- @return string|nil code
--- @return table|nil fields
function Booking.validateBook(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if type(input.frihetId) ~= 'number' or input.frihetId < 1 then
        return 'invalid', { frihetId = 'required' }
    end

    if input.cell ~= nil and (type(input.cell) ~= 'string' or #input.cell > 32) then
        return 'invalid', { cell = 'too_long' }
    end

    return nil
end

--- Checks a property line a route is about to add.
---
--- `itemLabel` is free text (the module header explains why) -- this only
--- bounds its shape, the same way `Personnel.validateDisciplineOpen` bounds
--- `summary` without judging its content.
---
--- @return string|nil code
--- @return table|nil fields
function Booking.validatePropertyAdd(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if type(input.bookingId) ~= 'number' or input.bookingId < 1 then
        return 'invalid', { bookingId = 'required' }
    end

    if type(input.itemLabel) ~= 'string' or #input.itemLabel == 0 or #input.itemLabel > 191 then
        return 'invalid', { itemLabel = 'required' }
    end

    if input.quantity ~= nil and (type(input.quantity) ~= 'number' or input.quantity < 1) then
        return 'invalid', { quantity = 'invalid' }
    end

    return nil
end

--- Checks a release from custody a route is about to write.
---
--- @return string|nil code
--- @return table|nil fields
function Booking.validateRelease(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if type(input.releaseReasonKey) ~= 'string' or input.releaseReasonKey == '' then
        return 'invalid', { releaseReasonKey = 'required' }
    end

    if not Booking.isReleaseReason(input.releaseReasonKey) then
        return 'invalid', { releaseReasonKey = 'not_a_key' }
    end

    return nil
end

FredPD.Modules.booking = Booking

return Booking
