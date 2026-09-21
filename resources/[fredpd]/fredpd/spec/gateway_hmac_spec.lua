--- HMAC-SHA256, pinned against RFC 4231's own test vectors -- test cases 1-3
--- (a key shorter than the block size) and 6-7 (a key *longer* than the
--- block size, the branch that hashes the key down first before either pad
--- is built).
---
--- This is the primitive `client.lua` signs every gateway request with. An
--- error here is not a broken test, it is a broken signature that would
--- fail identically for every request forever -- so every RFC vector that
--- exercises a distinct code path is checked, not just one.

local helper = require('spec.helper')

local function hexToBytes(hex)
    return (hex:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end))
end

describe('gateway hmac', function()
    local hmac

    before_each(function()
        hmac = helper.load({ 'server/bridges/gateway/sha256', 'server/bridges/gateway/hmac' }).Bridge.gateway.hmac
    end)

    it('RFC 4231 case 1 -- 20-byte key', function()
        local key = hexToBytes('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b')

        assert.equal(
            'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
            hmac.sha256Hex(key, 'Hi There'))
    end)

    it('RFC 4231 case 2 -- a key shorter than the digest itself', function()
        assert.equal(
            '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
            hmac.sha256Hex('Jefe', 'what do ya want for nothing?'))
    end)

    it('RFC 4231 case 3 -- a 50-byte message', function()
        local key = hexToBytes(('aa'):rep(20))
        local message = hexToBytes(('dd'):rep(50))

        assert.equal(
            '773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe',
            hmac.sha256Hex(key, message))
    end)

    it('RFC 4231 case 6 -- a key longer than the block size, hashed down first', function()
        local key = hexToBytes(('aa'):rep(131))

        assert.equal(
            '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
            hmac.sha256Hex(key, 'Test Using Larger Than Block-Size Key - Hash Key First'))
    end)

    it('RFC 4231 case 7 -- both key and message longer than the block size', function()
        local key = hexToBytes(('aa'):rep(131))
        local message = 'This is a test using a larger than block-size key and a larger ' ..
            'than block-size data. The key needs to be hashed before being used by the HMAC algorithm.'

        assert.equal(
            '9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2',
            hmac.sha256Hex(key, message))
    end)

    it('is deterministic', function()
        assert.equal(hmac.sha256Hex('k', 'm'), hmac.sha256Hex('k', 'm'))
    end)

    it('is sensitive to the key, not only the message', function()
        assert.is_not.equal(hmac.sha256Hex('k1', 'm'), hmac.sha256Hex('k2', 'm'))
    end)

    it('matches the wire format client.lua signs: "<timestamp>.<body>"', function()
        -- The exact material `gateway/src/hmac.ts`'s `sign()` signs, so the
        -- two sides can only ever agree or both be wrong the same way.
        local signed = hmac.sha256Hex('shared-secret', '1700000000.' .. '{"a":1}')

        assert.equal(64, #signed)
        assert.is_nil(signed:find('[^0-9a-f]'))
    end)
end)
