--- Lua mistakes that pass every other check and fail only at runtime.
---
--- `t[#t + 1], t[#t + 1] = a, b` looks like two appends. In Lua every index in
--- a multiple assignment is worked out before anything is assigned, so both
--- land in the same slot and the list gains one value, not two. Seven cursor
--- pages (anmalan, FU, spaning, tvångsmedel, the query log) sent fewer values
--- than their SQL had placeholders, so every "load more" failed, and nothing
--- noticed: busted fakes the database, and the mock NUI never runs Lua.

describe('lua pitfalls', function()
    it('the language does what this spec says it does', function()
        local t = { 'x' }
        t[#t + 1], t[#t + 1] = 'a', 'b'
        assert.are.equal(2, #t)
    end)

    it('no file appends twice in one multiple assignment', function()
        local offenders, scanned = {}, 0
        local listing = assert(io.popen('find resources -name "*.lua" -not -path "*/spec/*"'))

        --- `t[#t + 1]`, `t[#t+1]`, any spacing: the same append.
        local function appends(code, name)
            local escaped = name:gsub('%p', '%%%0')
            local _, count = code:gsub(escaped .. '%[#' .. escaped .. '%s*%+%s*1%]', '')
            return count
        end

        for path in listing:lines() do
            scanned = scanned + 1
            local number = 0
            for line in io.lines(path) do
                number = number + 1
                local code = line:gsub('%-%-.*$', '')
                -- A multiple assignment: a comma before the first `=`.
                local left = code:match('^(.-)[^=~<>]=[^=]')
                if left and left:find(',', 1, true) then
                    for name in left:gmatch('([%w_%.]+)%[#') do
                        if appends(left, name) > 1 then
                            offenders[#offenders + 1] = ('%s:%d'):format(path, number)
                            break
                        end
                    end
                end
            end
        end
        listing:close()

        -- Run from anywhere but the repository root, `find` finds nothing and
        -- the test would pass having read no file at all.
        assert.is_true(scanned > 100, 'scanned only ' .. scanned .. ' files; run busted from the repository root')
        assert.are.same({}, offenders)
    end)
end)
