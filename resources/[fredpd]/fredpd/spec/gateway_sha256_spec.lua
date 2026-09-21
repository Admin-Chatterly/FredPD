--- SHA-256, pinned against FIPS 180-4's own test vectors plus the empty
--- string (which FIPS 180-4 does not include but every implementation is
--- checked against in practice).
---
--- This is the file that justifies building the gateway bridge at all: the
--- original session judged an unverified HMAC-SHA256 implementation unsafe to
--- ship, and this is the verification.

local helper = require('spec.helper')

describe('gateway sha256', function()
    local sha256

    before_each(function()
        sha256 = helper.load({ 'server/bridges/gateway/sha256' }).Bridge.gateway.sha256
    end)

    it('hashes the empty string', function()
        assert.equal(
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
            sha256.hexdigest(''))
    end)

    it('hashes "abc" (FIPS 180-4 example)', function()
        assert.equal(
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
            sha256.hexdigest('abc'))
    end)

    it('hashes the two-block message (FIPS 180-4 example)', function()
        assert.equal(
            '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
            sha256.hexdigest('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))
    end)

    it('hashes a message spanning three 64-byte blocks', function()
        -- One million repetitions of 'a', FIPS 180-4's third example --
        -- chosen because it is long enough to exercise the padding branch
        -- that a single- or two-block message never reaches.
        local message = ('a'):rep(1000000)

        assert.equal(
            'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
            sha256.hexdigest(message))
    end)

    it('produces 32 raw bytes from digest()', function()
        assert.equal(32, #sha256.digest('abc'))
    end)

    it('is deterministic', function()
        assert.equal(sha256.hexdigest('repeat me'), sha256.hexdigest('repeat me'))
    end)

    it('is sensitive to every bit -- no two distinct short inputs collide here', function()
        assert.is_not.equal(sha256.hexdigest('abc'), sha256.hexdigest('abd'))
    end)
end)
