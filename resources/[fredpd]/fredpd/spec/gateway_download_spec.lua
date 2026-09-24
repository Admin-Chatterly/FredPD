--- Download links FXServer signs itself (ADR-019) must be exactly what the
--- gateway would have signed: the vector below is Node's own
--- `createHmac('sha256', deriveKey('test-secret', 'media-download'))` over
--- `<ref>.download.<expires>`, as `gateway/src/media/tokens.ts` computes it.

local helper = require('spec.helper')

describe('gateway download links', function()
    local service

    before_each(function()
        local fredpd = helper.load({
            'server/bridges/gateway/sha256',
            'server/bridges/gateway/hmac',
        })

        fredpd.Config = {
            server = {
                gateway = {
                    enabled = true,
                    secret = 'test-secret',
                    url = 'http://127.0.0.1:3080',
                    mediaUrl = 'https://media.example/',
                    mediaLinkSeconds = 900,
                },
            },
        }
        fredpd.Bridge.gateway.client = { isEnabled = function() return true end }

        -- Loaded into the namespace above, not through `helper.load`, which
        -- would start a fresh one without the client stub.
        assert(loadfile('resources/[fredpd]/fredpd/server/bridges/gateway/service.lua'))()
        service = FredPD.Bridge.gateway.service
    end)

    it('signs the way the gateway verifies', function()
        local url = service.downloadUrl('media_00000000-0000-0000-0000-000000000001', false, 1790000000 - 900)

        assert.are.equal(
            'https://media.example/media/media_00000000-0000-0000-0000-000000000001'
                .. '?token=6608113764cd35e4d3c076b78281928b50352c9b713042c2da53ad9e0e6bcfc5&expires=1790000000',
            url)
    end)

    it('points a thumbnail at the thumbnail route with the same token', function()
        local url = service.downloadUrl('media_00000000-0000-0000-0000-000000000001', true)
        assert.truthy(url:find('/media/media_00000000%-0000%-0000%-0000%-000000000001/thumbnail%?token='))
    end)

    it('signs nothing that is not a media ref', function()
        assert.is_nil(service.downloadUrl('../etc/passwd'))
        assert.is_nil(service.downloadUrl(nil))
    end)
end)
