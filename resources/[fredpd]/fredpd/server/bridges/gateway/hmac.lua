--- HMAC-SHA256 (RFC 2104), built on `sha256.lua`.
---
--- No natives, so `spec/gateway_hmac_spec.lua` pins it against every RFC 4231
--- test vector outside FXServer -- the same reasoning `sha256.lua`'s header
--- gives at length. This is the one function the gateway bridge actually
--- signs requests with; `sha256.lua` alone is not enough on its own (a plain
--- hash of `secret .. message` is length-extendable, which is exactly why
--- HMAC exists and why the gateway's own `gateway/src/hmac.ts` uses it too).

FredPD = FredPD or {}
FredPD.Bridge = FredPD.Bridge or {}
FredPD.Bridge.gateway = FredPD.Bridge.gateway or {}

local sha256 = FredPD.Bridge.gateway.sha256

local Hmac = {}

local BLOCK_SIZE <const> = 64
local IPAD <const> = 0x36
local OPAD <const> = 0x5c

--- @param key string
--- @param message string
--- @return string digest 32 raw bytes, not hex
function Hmac.sha256(key, message)
    if #key > BLOCK_SIZE then key = sha256.digest(key) end
    if #key < BLOCK_SIZE then key = key .. string.rep('\0', BLOCK_SIZE - #key) end

    local ipad, opad = {}, {}
    for index = 1, BLOCK_SIZE do
        local byte = key:byte(index)
        ipad[index] = string.char(byte ~ IPAD)
        opad[index] = string.char(byte ~ OPAD)
    end

    return sha256.digest(table.concat(opad) .. sha256.digest(table.concat(ipad) .. message))
end

--- @param key string
--- @param message string
--- @return string hex 64 lowercase hex characters
function Hmac.sha256Hex(key, message)
    return (Hmac.sha256(key, message):gsub('.', function(byte)
        return string.format('%02x', byte:byte())
    end))
end

FredPD.Bridge.gateway.hmac = Hmac

return Hmac
