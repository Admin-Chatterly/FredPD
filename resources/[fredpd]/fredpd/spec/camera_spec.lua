--- Cameras (spec 7.19): what a footage request must say, and when it lets
--- its requester look.

local helper = require('spec.helper')

describe('camera service', function()
    local C
    local NOW <const> = 1790000000

    before_each(function()
        C = helper.load({ 'server/modules/camera/service' }).Modules.camera
    end)

    local function valid(overrides)
        local input = {
            source = 'cctv', cameraId = 12, windowFrom = NOW, windowTo = NOW + 7200, reason = 'Robbery at the store',
        }
        for key, value in pairs(overrides or {}) do input[key] = value end
        return C.validateRequest(input, NOW, 12)
    end

    it('takes a CCTV request naming its camera, a window and why', function()
        local request = valid()
        assert.are.equal(12, request.cameraId)
        assert.is_nil(request.officerId)
        assert.are.equal('Robbery at the store', request.reason)
    end)

    it('asks a body-worn or dash request for its officer, and drops a stray camera id', function()
        local _, fields = valid({ source = 'bodycam', cameraId = 12 })
        assert.are.same({ officerId = 'required' }, fields)

        local request = valid({ source = 'dashcam', officerId = 4, cameraId = 12 })
        assert.are.equal(4, request.officerId)
        assert.is_nil(request.cameraId)
    end)

    it('refuses a window that is backwards, long past, too far ahead or too long', function()
        local _, fields = valid({ windowTo = NOW - 10 })
        assert.are.same({ windowTo = 'out_of_range' }, fields)

        _, fields = valid({ windowFrom = NOW - 2 * 86400, windowTo = NOW - 86400 })
        assert.are.same({ windowFrom = 'out_of_range' }, fields)

        _, fields = valid({ windowFrom = NOW + 8 * 86400, windowTo = NOW + 8 * 86400 + 60 })
        assert.are.same({ windowFrom = 'out_of_range' }, fields)

        _, fields = valid({ windowTo = NOW + 13 * 3600 })
        assert.are.same({ windowTo = 'too_long' }, fields)
    end)

    it('lets an approved request look only through its own camera, only while its window is open', function()
        local request = { status = 'approved', source = 'cctv', cameraId = 12, windowFrom = NOW - 60, windowTo = NOW + 60 }

        assert.is_true(C.covers(request, 'cctv', 12, nil, NOW))
        assert.is_false(C.covers(request, 'cctv', 13, nil, NOW))
        assert.is_false(C.covers(request, 'bodycam', nil, 12, NOW))
        assert.is_false(C.covers(request, 'cctv', 12, nil, NOW + 120))

        request.status = 'requested'
        assert.is_false(C.covers(request, 'cctv', 12, nil, NOW))
    end)

    it('mounts a body-worn camera on the chest and a dash camera behind the windscreen, facing forward', function()
        -- Heading 0 faces north (+y) in GTA.
        local body = C.mount('bodycam', 0, 0, 0, 0)
        assert.is_true(body.y > 0 and math.abs(body.x) < 1e-9)
        assert.is_true(body.z > 0)

        local dash = C.mount('dashcam', 0, 0, 0, 90)
        -- Heading 90 faces west (-x).
        assert.is_true(dash.x < 0 and math.abs(dash.y) < 1e-9)
    end)

    it('numbers a request the Appendix D way', function()
        local prefix, width = C.numberPrefix(2026)
        assert.are.equal('F26-', prefix)
        assert.are.equal(5, width)
    end)
end)
