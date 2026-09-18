--- The vehicle and firearm registry logic (spec 7.4, 7.5).
---
--- Two things here are worth testing more than the rest, and they are the two
--- the rest of the module trusts:
---
---   * **the VIN generator**, because a VIN is generated once and then *is* the
---     vehicle's identity (invariant 1), and a generator that produced an
---     invalid or predictable one would not fail until somebody typed a real
---     VIN into a query and got somebody else's car;
---   * **`opensRestricted`**, because it decides when a query needs a reason
---     (7.2), and a mistake in it either asks for a reason on every ordinary
---     plate check or lets a restricted record out without one.

local helper = require('spec.helper')

describe('registry', function()
    local registry

    before_each(function()
        registry = helper.load({ 'server/modules/registry/service' }).Modules.registry
    end)

    -- -------------------------------------------------------------------------
    describe('normalisation', function()
        it('upper-cases a plate and removes the spaces inside it', function()
            assert.are.equal('ABC123', registry.normalizePlate('  abc 123 '))
        end)

        it('treats a blank plate as absent', function()
            assert.is_nil(registry.normalizePlate('   '))
            assert.is_nil(registry.normalizePlate(''))
            assert.is_nil(registry.normalizePlate(nil))
            assert.is_nil(registry.normalizePlate(42))
        end)

        it('normalises a serial the same way a plate is', function()
            assert.are.equal('GLK17-8842', registry.normalizeSerial(' glk17-8842 '))
        end)

        it('refuses a search term of one character', function()
            assert.is_nil(registry.searchTerm('a'))
            assert.are.equal('AB', registry.searchTerm(' ab '))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('VIN', function()
        --- The worked example from ISO 3779: its check digit is X.
        local EXAMPLE <const> = '1M8GDM9AXKP042788'

        it('computes the standard check digit', function()
            assert.are.equal('X', registry.vinCheckDigit(EXAMPLE))
        end)

        it('accepts a VIN whose check digit is right', function()
            assert.is_true(registry.isVin(EXAMPLE))
        end)

        it('rejects one character off', function()
            assert.is_false(registry.isVin('1M8GDM9AXKP042789'))
        end)

        it('rejects I, O and Q, which are not VIN characters', function()
            assert.is_false(registry.isVin('1M8GDM9AXKP04278O'))
            assert.is_nil(registry.vinCheckDigit('IIIIIIIIIIIIIIIII'))
        end)

        it('rejects anything that is not seventeen characters', function()
            assert.is_false(registry.isVin('1M8GDM9AXKP04278'))
            assert.is_false(registry.isVin(''))
            assert.is_false(registry.isVin(nil))
        end)

        it('generates a VIN that validates', function()
            for _ = 1, 200 do
                local vin = registry.generateVin()

                assert.are.equal(17, #vin)
                assert.is_true(registry.isVin(vin))
            end
        end)

        it('never generates I, O or Q', function()
            for _ = 1, 200 do
                assert.is_nil(registry.generateVin():find('[IOQ]'))
            end
        end)

        it('computes the check digit over what was drawn, not over a constant', function()
            -- A deterministic draw, so the VIN is varied and the check digit
            -- has work to do: if it were pasted in rather than computed, this
            -- is where it would show.
            local drawn = 0

            local vin = registry.generateVin(function(_, max)
                drawn = drawn % max + 1
                return drawn
            end)

            assert.are.equal(17, #vin)
            assert.is_true(registry.isVin(vin))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('hot file', function()
        it('reports stolen, wanted and BOLO as hits', function()
            local hits = registry.vehicleHits({
                { kind = 'wanted' }, { kind = 'stolen' }, { kind = 'bolo' },
            })

            assert.are.same({ 'bolo', 'stolen', 'wanted' }, hits)
        end)

        it('does not report an impound or a lapsed insurance as a hit', function()
            assert.are.same({}, registry.vehicleHits({
                { kind = 'impounded' }, { kind = 'uninsured' },
            }))
        end)

        it('reports each kind once, however many flags carry it', function()
            assert.are.same({ 'stolen' }, registry.vehicleHits({
                { kind = 'stolen' }, { kind = 'stolen' },
            }))
        end)

        it('ignores a stub, which carries no kind', function()
            assert.are.same({ 'stolen' }, registry.vehicleHits({
                { restricted = true, contact = 'narcotics' }, { kind = 'stolen' },
            }))
        end)

        it('reports a lost or stolen firearm and nothing else', function()
            assert.are.same({ 'stolen' }, registry.firearmHits({ status = 'stolen' }))
            assert.are.same({ 'lost' }, registry.firearmHits({ status = 'lost' }))
            assert.are.same({}, registry.firearmHits({ status = 'registered' }))
            assert.are.same({}, registry.firearmHits(nil))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('statusEvent', function()
        it('names the event a status change writes into the history', function()
            assert.are.equal('lost', registry.statusEvent('lost'))
            assert.are.equal('stolen', registry.statusEvent('stolen'))
            assert.are.equal('destroyed', registry.statusEvent('destroyed'))
            assert.are.equal('seized', registry.statusEvent('seized'))
        end)

        it('calls going back to registered a recovery, because that is what it is', function()
            assert.are.equal('recovered', registry.statusEvent('registered'))
        end)

        it('calls an agency weapon issued', function()
            assert.are.equal('issued', registry.statusEvent('agency_issued'))
        end)

        it('refuses a status the register does not have', function()
            assert.is_nil(registry.statusEvent('confiscated'))
            assert.is_nil(registry.statusEvent(nil))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('paging', function()
        it('over-fetches, because access filtering removes rows afterwards', function()
            local window, limit = registry.fetchWindow(25)

            assert.are.equal(75, window)
            assert.are.equal(25, limit)
        end)

        it('caps what a client may ask for', function()
            local _, limit = registry.fetchWindow(5000)
            assert.are.equal(100, limit)
        end)

        it('falls back to the default when nothing is asked for', function()
            local _, limit = registry.fetchWindow(nil, 10)
            assert.are.equal(10, limit)
        end)

        it('trims a filtered list back to the page', function()
            assert.are.same({ 1, 2 }, registry.trim({ 1, 2, 3, 4 }, 2))
            assert.are.same({ 1 }, registry.trim({ 1 }, 4))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('opensRestricted', function()
        local function restrictedRows()
            return {
                { id = 1, classification = 'internal' },
                { id = 2, classification = 'confidential' },
            }
        end

        local function isRestricted(row)
            return row.classification == 'confidential'
        end

        it('is true when a restricted record was opened', function()
            assert.is_true(registry.opensRestricted(restrictedRows(), isRestricted))
        end)

        it('is false for ordinary records', function()
            assert.is_false(registry.opensRestricted(
                { { id = 1, classification = 'internal' } }, isRestricted
            ))
        end)

        it('does not count a stub, which discloses nothing but existence', function()
            local rows = { { restricted = true, contact = 'narcotics' } }

            assert.is_false(registry.opensRestricted(rows, isRestricted))
        end)

        it('is false when it is handed nothing it can judge', function()
            assert.is_false(registry.opensRestricted(nil, isRestricted))
            assert.is_false(registry.opensRestricted({}, isRestricted))
            assert.is_false(registry.opensRestricted(restrictedRows(), nil))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('validation', function()
        it('refuses a flag kind the register does not have', function()
            local err, fields = registry.validateFlag({ kind = 'suspicious' })

            assert.are.equal('invalid', err)
            assert.are.equal('not_allowed', fields.kind)
        end)

        it('makes a hot-file flag say where it came from', function()
            local err, fields = registry.validateFlag({ kind = 'stolen' })

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.caseNumber)
        end)

        it('accepts a hot-file flag with a case number, or with a detail', function()
            assert.is_nil(registry.validateFlag({ kind = 'stolen', caseNumber = 'LSPD-26-000123' }))
            assert.is_nil(registry.validateFlag({ kind = 'bolo', detail = 'Seen on Route 68' }))
        end)

        it('does not demand a case number for an administrative flag', function()
            assert.is_nil(registry.validateFlag({ kind = 'uninsured' }))
        end)

        it('refuses a classification that is not one of the five', function()
            local err, fields = registry.validateFlag({ kind = 'uninsured', classification = 'cosmic' })

            assert.are.equal('invalid', err)
            assert.are.equal('not_allowed', fields.classification)
        end)

        it('refuses a transfer to nobody', function()
            local err, fields = registry.validateTransfer({})

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.toPersonId)
        end)

        it('accepts a transfer to a person on file or to a named party', function()
            assert.is_nil(registry.validateTransfer({ toPersonId = 7 }))
            assert.is_nil(registry.validateTransfer({ toParty = 'Ammu-Nation, Vinewood' }))
        end)

        it('makes a loss, a theft, a seizure and a destruction give a reason', function()
            for _, status in ipairs({ 'lost', 'stolen', 'seized', 'destroyed' }) do
                local err, fields = registry.validateStatus({ status = status })

                assert.are.equal('invalid', err)
                assert.are.equal('required', fields.reason)
            end
        end)

        it('accepts a reported theft with a case number', function()
            assert.is_nil(registry.validateStatus({ status = 'stolen', caseNumber = 'LSPD-26-000123' }))
        end)

        it('refuses a status that is not one of the six', function()
            local err, fields = registry.validateStatus({ status = 'melted' })

            assert.are.equal('invalid', err)
            assert.are.equal('not_allowed', fields.status)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('queryType', function()
        it('calls a valid seventeen-character identifier a VIN', function()
            assert.are.equal('vin', registry.queryType('1M8GDM9AXKP042788'))
        end)

        it('calls anything else a plate', function()
            assert.are.equal('plate', registry.queryType('ABC123'))
            assert.are.equal('plate', registry.queryType(nil))
        end)
    end)
end)
