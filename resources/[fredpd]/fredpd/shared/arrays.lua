--- Marking Lua lists so they encode as JSON arrays.
---
--- An empty Lua table is both `{}` and `[]`, and every JSON encoder has to
--- guess which. They all guess object, so a route answering with an empty list
--- -- a group created from the editor with no permissions of its own, a search
--- with no hits, a case with no notes -- reaches the interface as `{}`, where
--- `length` is `undefined` and an `{#each}` over it throws. That is a broken
--- page on the first click after a create, in every module.
---
--- Shared rather than server-side, because of where the guess is actually made.
--- A route's answer crosses to the client through `lib.callback`, which is
--- msgpack and carries no metatables, and the JSON the browser parses is
--- written in the *client* runtime by `cb(...)` in `client/main.lua`. Marking a
--- table on the server is therefore correct and invisible: whatever the server
--- marks, the client hands its encoder a bare table. The mark has to be applied
--- on the hop that encodes, so the rule lives here and both sides call it.
---
--- The mark itself must be one the encoder recognises. FiveM's Lua JSON is
--- lua-cjson, which decides from the metatables it exports (`json.array_mt`,
--- and `json.empty_array_mt` for the empty case) and not from a marker of our
--- own invention -- a plain `{ __jsontype = 'array' }` is the fix that looks
--- right and encodes nothing differently. A runtime exporting neither (busted,
--- and any encoder that already writes a sequence as an array) leaves
--- `ARRAY_MT` nil and the walk becomes a no-op rather than an error.

FredPD = FredPD or {}

local ARRAY_MT = (type(json) == 'table' and (rawget(json, 'array_mt') or rawget(json, 'empty_array_mt')))
    or nil

--- How deep the walk goes. A response is a record, not a tree; anything past
--- this is a bug somewhere else and is left alone rather than chased.
local MAX_DEPTH <const> = 12

--- True when `value` is a sequence: the keys 1..n, or no keys at all.
---
--- An empty table counts, which is the whole point -- and is also the one
--- judgement call here. A route that means to return an empty *object* has to
--- say so some other way, because nothing in the table itself can say it.
local function isSequence(value)
    local count = 0

    for key in pairs(value) do
        if type(key) ~= 'number' then return false end
        count = count + 1
    end

    return count == #value
end

--- Marks every list in a value so it encodes as a JSON array.
---
--- Walks the whole value: a list of rows each carrying lists of their own is
--- the normal shape here, and the empty one is usually the nested one. A table
--- that already carries a metatable is left alone, and a cycle is visited once.
---
--- Recurses through a local rather than through `FredPD.markArrays`, so the
--- walk cannot be broken by anything that reassigns the field afterwards.
---
--- @param value any
--- @return any the same value, marked in place
local function markArrays(value, seen, depth)
    if type(value) ~= 'table' then return value end

    depth = depth or 1
    if depth > MAX_DEPTH then return value end

    seen = seen or {}
    if seen[value] then return value end
    seen[value] = true

    for _, entry in pairs(value) do
        markArrays(entry, seen, depth + 1)
    end

    if ARRAY_MT and getmetatable(value) == nil and isSequence(value) then
        setmetatable(value, ARRAY_MT)
    end

    return value
end

FredPD.markArrays = markArrays
