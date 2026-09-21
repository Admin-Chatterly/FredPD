--- Surveillance: the secret coercive measures (spec 9).
---
--- **`isValid` is what this file is for**, the same way it is the point of
--- `tvangsmedel_spec.lua`: spec 14 exposes it as `HasActiveWarrant`, and every
--- way of being invalid needs its own name so a caller can say why rather than
--- merely that. The capacity matrix matters just as much -- an åklagare who
--- could grant their own application would make the tingsrätt gate decorative.

local helper = require('spec.helper')

describe('surveillance', function()
    local surveillance

    before_each(function()
        surveillance = helper.load({ 'server/modules/surveillance/service' }).Modules.surveillance
    end)

    local NOW <const> = 1000000

    local function measure(overrides)
        local base = {
            id = 1,
            fuId = 4,
            targetKind = 'person',
            targetId = 9,
            method = 'hak',
            status = 'beviljad',
            validFrom = NOW - 3600,
            validUntil = NOW + 3600,
        }

        for key, value in pairs(overrides or {}) do
            base[key] = value ~= helper.NONE and value or nil
        end

        return base
    end

    -- -------------------------------------------------------------------------
    describe('isValid', function()
        it('is live once granted and inside its window', function()
            assert.is_true(surveillance.isValid(measure(), NOW))
        end)

        it('is not live while only requested', function()
            local live, why = surveillance.isValid(measure({ status = 'begard' }), NOW)
            assert.is_false(live)
            assert.are.equal('begard', why)
        end)

        it('is not live once refused', function()
            local live, why = surveillance.isValid(measure({ status = 'avslagen' }), NOW)
            assert.is_false(live)
            assert.are.equal('avslagen', why)
        end)

        it('is never live once revoked, whatever the window says', function()
            -- RB 27:23: grounds may cease before the window does, and the
            -- revocation overrides it immediately.
            local live, why = surveillance.isValid(
                measure({ upphavdAt = NOW - 60 }), NOW)

            assert.is_false(live)
            assert.are.equal('upphavd', why)
        end)

        it('is not live before its window opens', function()
            local live, why = surveillance.isValid(
                measure({ validFrom = NOW + 60 }), NOW)

            assert.is_false(live)
            assert.are.equal('not_yet', why)
        end)

        it('is not live after its window closes', function()
            local live, why = surveillance.isValid(
                measure({ validUntil = NOW - 60 }), NOW)

            assert.is_false(live)
            assert.are.equal('expired', why)
        end)

        it('fails closed on a missing row', function()
            local live, why = surveillance.isValid(nil, NOW)
            assert.is_false(live)
            assert.are.equal('not_found', why)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('firstValid', function()
        it('finds the first live measure for a target', function()
            local rows = {
                measure({ id = 1, status = 'avslagen' }),
                measure({ id = 2 }),
                measure({ id = 3 }),
            }

            local found = surveillance.firstValid(rows, NOW)
            assert.are.equal(2, found.id)
        end)

        it('narrows by method when one is given', function()
            local rows = {
                measure({ id = 1, method = 'hak' }),
                measure({ id = 2, method = 'sparsandare' }),
            }

            local found = surveillance.firstValid(rows, NOW, 'sparsandare')
            assert.are.equal(2, found.id)
        end)

        it('finds nothing when every row is invalid', function()
            local rows = { measure({ status = 'begard' }), measure({ status = 'avslagen' }) }
            assert.is_nil(surveillance.firstValid(rows, NOW))
        end)
    end)

    -- -------------------------------------------------------------------------
    -- The capacity matrix: only a domare may grant, and both a domare and the
    -- åklagare who applied may revoke early.
    -- -------------------------------------------------------------------------
    describe('the capacity matrix', function()
        it('lets only the åklagare request', function()
            assert.is_true(surveillance.mayRequest('aklagare'))
            assert.is_false(surveillance.mayRequest('domare'))
            assert.is_false(surveillance.mayRequest('polis'))
            assert.is_false(surveillance.mayRequest(nil))
        end)

        it('lets only the domare grant', function()
            -- The whole point of 0015's chain: an åklagare who could grant
            -- their own application would make the tingsrätt gate decorative.
            assert.is_true(surveillance.mayGrant('domare'))
            assert.is_false(surveillance.mayGrant('aklagare'))
            assert.is_false(surveillance.mayGrant('polis'))
        end)

        it('lets either the åklagare or the domare revoke early', function()
            assert.is_true(surveillance.mayUpphav('aklagare'))
            assert.is_true(surveillance.mayUpphav('domare'))
            assert.is_false(surveillance.mayUpphav('polis'))
            assert.is_false(surveillance.mayUpphav(nil))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('needsRenewal', function()
        it('warns inside the last day of a live window', function()
            assert.is_true(surveillance.needsRenewal(
                measure({ validUntil = NOW + 3600 }), NOW))
        end)

        it('does not warn with more than a day left', function()
            assert.is_false(surveillance.needsRenewal(
                measure({ validUntil = NOW + (2 * 24 * 3600) }), NOW))
        end)

        it('does not warn about a measure that is not live', function()
            assert.is_false(surveillance.needsRenewal(
                measure({ status = 'begard', validFrom = nil, validUntil = nil }), NOW))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('bannerFor', function()
        it('shows a pending request as pending', function()
            assert.are.equal('pending', surveillance.bannerFor(
                measure({ status = 'begard', validFrom = nil, validUntil = nil }), NOW))
        end)

        it('shows a live grant as active', function()
            assert.are.equal('active', surveillance.bannerFor(measure(), NOW))
        end)

        it('shows a refused or revoked or expired one as closed', function()
            assert.are.equal('closed', surveillance.bannerFor(
                measure({ status = 'avslagen' }), NOW))
            assert.are.equal('closed', surveillance.bannerFor(
                measure({ upphavdAt = NOW - 60 }), NOW))
            assert.are.equal('closed', surveillance.bannerFor(
                measure({ validUntil = NOW - 60 }), NOW))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('isInterceptKind', function()
        it('accepts a well-formed key', function()
            assert.is_true(surveillance.isInterceptKind('surveillance.intercept.call'))
            assert.is_true(surveillance.isInterceptKind('surveillance.intercept.doorbell'))
        end)

        it('refuses prose', function()
            -- The whole point: `t()` prints an unknown key verbatim, so a
            -- sentence here would be drawn as a label in both locales.
            assert.is_false(surveillance.isInterceptKind('heard him say he would run'))
        end)

        it('refuses a key from a different namespace', function()
            assert.is_false(surveillance.isInterceptKind('frihet.logKind.forhor'))
        end)

        it('refuses a missing or non-string value', function()
            assert.is_false(surveillance.isInterceptKind(nil))
            assert.is_false(surveillance.isInterceptKind(42))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('validateRequest', function()
        local function request(overrides)
            local base = {
                fuId = 4,
                targetKind = 'person',
                targetId = 9,
                method = 'hak',
                grund = 'skalig_misstanke',
            }

            for key, value in pairs(overrides or {}) do
                base[key] = value ~= helper.NONE and value or nil
            end

            return base
        end

        it('accepts a well-formed request', function()
            assert.is_nil(surveillance.validateRequest(request()))
        end)

        it('refuses a request naming no investigation', function()
            local err, fields = surveillance.validateRequest(request({ fuId = helper.NONE }))
            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.fuId)
        end)

        it('refuses an unknown target kind', function()
            local err, fields = surveillance.validateRequest(
                request({ targetKind = 'email' }))

            assert.are.equal('invalid', err)
            assert.are.equal('unknown', fields.targetKind)
        end)

        it('accepts a phone target with only a label', function()
            assert.is_nil(surveillance.validateRequest(request({
                targetKind = 'phone', targetId = helper.NONE, targetLabel = '070-1234567',
            })))
        end)

        it('refuses a phone target carrying a record id', function()
            -- A telephone number is not a foreign key into anything this
            -- suite holds (0015).
            local err, fields = surveillance.validateRequest(request({
                targetKind = 'phone', targetId = 9, targetLabel = '070-1234567',
            }))

            assert.are.equal('invalid', err)
            assert.are.equal('not_allowed', fields.targetId)
        end)

        it('refuses a target with neither an id nor a label', function()
            local err, fields = surveillance.validateRequest(request({
                targetId = helper.NONE,
            }))

            assert.are.equal('invalid', err)
            assert.are.equal('required_without_target', fields.targetLabel)
        end)

        it('refuses an unknown method', function()
            local err, fields = surveillance.validateRequest(request({ method = 'gps' }))
            assert.are.equal('invalid', err)
            assert.are.equal('unknown', fields.method)
        end)

        it('refuses a ground that is not a locale key', function()
            -- The NUI renders it with `t()`, which prints an unknown key
            -- verbatim on a page a domare reads before deciding whether to
            -- watch somebody.
            local err, fields = surveillance.validateRequest(
                request({ grund = 'because I felt like it' }))

            assert.are.equal('invalid', err)
            assert.are.equal('not_a_key', fields.grund)
        end)
    end)
end)
