--- SHA-256 (FIPS 180-4), pure Lua 5.4.
---
--- The gateway bridge (spec 3.7) signs every request with HMAC-SHA256, and
--- Lua ships no hash natives -- FXServer's runtime has no `crypto` module the
--- way Node does. This is the primitive `hmac.lua` builds on. It is pure
--- arithmetic on strings and integers: no natives, so busted can pin it
--- against the standard test vectors outside FXServer, which is what
--- `spec/gateway_sha256_spec.lua` does against every vector in FIPS 180-4 and
--- RFC 4231 -- an unverified hash implementation is worse than no bridge at
--- all, since it would fail silently rather than refuse to sign.
---
--- Lua 5.4's native 64-bit integers and bitwise operators make this far
--- shorter than the bit-twiddling libraries written for 5.1, where every
--- operation had to be its own function.

FredPD = FredPD or {}
FredPD.Bridge = FredPD.Bridge or {}
FredPD.Bridge.gateway = FredPD.Bridge.gateway or {}

local Sha256 = {}

local band, bxor, bnot = function(a, b) return a & b end, function(a, b) return a ~ b end,
    function(a) return ~a & 0xFFFFFFFF end
local function rrotate(x, n) return ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF end
local function rshift(x, n) return (x & 0xFFFFFFFF) >> n end

--- The 64 round constants: the fractional parts of the cube roots of the
--- first 64 primes.
local K <const> = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

--- The initial hash value: the fractional parts of the square roots of the
--- first 8 primes.
local H0 <const> = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

--- Pads a message to a multiple of 64 bytes: a `1` bit, zeros, then the
--- original bit length as a big-endian 64-bit integer (FIPS 180-4 5.1.1).
local function pad(message)
    local bitLength = #message * 8

    message = message .. '\128'
    while (#message % 64) ~= 56 do message = message .. '\0' end

    return message .. string.pack('>I8', bitLength)
end

--- @param message string
--- @return string digest 32 raw bytes, not hex
function Sha256.digest(message)
    message = pad(message)
    local h1, h2, h3, h4, h5, h6, h7, h8 = table.unpack(H0)

    for chunkStart = 1, #message, 64 do
        local w = {}

        for t = 0, 15 do
            w[t] = string.unpack('>I4', message, chunkStart + t * 4)
        end

        for t = 16, 63 do
            local s0 = bxor(bxor(rrotate(w[t - 15], 7), rrotate(w[t - 15], 18)), rshift(w[t - 15], 3))
            local s1 = bxor(bxor(rrotate(w[t - 2], 17), rrotate(w[t - 2], 19)), rshift(w[t - 2], 10))
            w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xFFFFFFFF
        end

        local a, b, c, d, e, f, g, h = h1, h2, h3, h4, h5, h6, h7, h8

        for t = 0, 63 do
            local bigS1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = (h + bigS1 + ch + K[t + 1] + w[t]) & 0xFFFFFFFF
            local bigS0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local temp2 = (bigS0 + maj) & 0xFFFFFFFF

            h, g, f = g, f, e
            e = (d + temp1) & 0xFFFFFFFF
            d, c, b = c, b, a
            a = (temp1 + temp2) & 0xFFFFFFFF
        end

        h1 = (h1 + a) & 0xFFFFFFFF
        h2 = (h2 + b) & 0xFFFFFFFF
        h3 = (h3 + c) & 0xFFFFFFFF
        h4 = (h4 + d) & 0xFFFFFFFF
        h5 = (h5 + e) & 0xFFFFFFFF
        h6 = (h6 + f) & 0xFFFFFFFF
        h7 = (h7 + g) & 0xFFFFFFFF
        h8 = (h8 + h) & 0xFFFFFFFF
    end

    return string.pack('>I4I4I4I4I4I4I4I4', h1, h2, h3, h4, h5, h6, h7, h8)
end

--- @param message string
--- @return string hex 64 lowercase hex characters
function Sha256.hexdigest(message)
    return (Sha256.digest(message):gsub('.', function(byte)
        return string.format('%02x', byte:byte())
    end))
end

FredPD.Bridge.gateway.sha256 = Sha256

return Sha256
