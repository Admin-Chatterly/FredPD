--- The media ledger's pure rules (ADR-019).

local helper = require('spec.helper')

describe('media service', function()
    local M

    before_each(function()
        M = helper.load({ 'server/modules/media/service' }).Modules.media
    end)

    it('takes a mugshot under the booking terminal\'s permission, anything else under the record\'s', function()
        assert.are.equal('booking.intake', M.permissionFor('mugshot'))
        assert.are.equal('rms.person.photo.upload', M.permissionFor('field'))
        assert.are.equal('rms.person.photo.upload', M.permissionFor('tattoo'))
    end)

    it('knows the photograph kinds and nothing else', function()
        assert.is_true(M.isPhotoKind('scar'))
        assert.is_false(M.isPhotoKind('selfie'))
    end)

    it('accepts only refs of the shape the gateway issues', function()
        assert.is_true(M.isRef('media_0b8c5f1e-1d2a-4c3b-9e8f-7a6b5c4d3e2f'))
        assert.is_false(M.isRef('../media_x'))
        assert.is_false(M.isRef('media_' .. ('a'):rep(70)))
        assert.is_false(M.isRef(nil))
    end)

    it('gives a begun upload longer than the gateway gives its upload link', function()
        assert.is_true(M.PENDING_SECONDS > 300)
    end)
end)
