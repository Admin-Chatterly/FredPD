--- Discord role sync (spec 4.2, invariant 2, ADR-010).
---
--- Discord roles are the only thing that grants access in FredPD, so something
--- has to put them in `fpd_discord_members` for `perms.memberRoles()` to read.
--- That was going to be a bot inside the Node gateway. It is done here instead,
--- in Lua, because FXServer can call the Discord API perfectly well by itself
--- and asking an operator to deploy a Node service to fill one table is a cost
--- with nothing behind it (ADR-010).
---
--- Two triggers, for two different needs:
---
---   * every player who connects is refreshed immediately, so a role granted
---     seconds ago is live when they join;
---   * the whole member list is refreshed on a timer, so a role *removed* in
---     Discord takes effect without the member doing anything.
---
--- What this module deliberately does NOT do is write a row it could not
--- verify. When Discord is unreachable the stored rows simply age, and the
--- two-tier outage policy in `session.lua` narrows what a session may do as
--- they do. Freshening `synced_at` on a failed fetch would forge exactly the
--- signal that policy depends on.
---
--- The token never leaves this file: not to a client, not to the audit log,
--- not to a print.
---
--- The pure functions at the top contain no natives so busted can test them,
--- which is the rule spec 3.4 sets for anything worth testing.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Discord = {}

local API <const> = 'https://discord.com/api/v10'
local PAGE_SIZE <const> = 1000
local HTTP_TIMEOUT_MS <const> = 15000

--- Stops a connection flood turning into a request flood against Discord: a
--- member refreshed this recently is left alone. Well under the staleness
--- thresholds in spec 4.2, so it never makes a session look fresher than it is.
local CONNECT_COOLDOWN_SECONDS <const> = 30

--- Enough pages for a guild of a million members. The cursor strictly increases
--- so the walk terminates on its own; this is the backstop for the case where
--- it somehow does not, because the alternative is a thread that never ends.
local MAX_PAGES <const> = 1000

--- discord id -> os.time() of the last successful single-member refresh.
local lastRefreshedAt = {}

-- -----------------------------------------------------------------------------
-- Pure. No natives, no database.
-- -----------------------------------------------------------------------------

--- The role ids on one guild-member payload, as strings.
---
--- Discord sends role ids as strings already, and they must stay strings: a
--- snowflake is a 64-bit integer and Lua numbers would round the low bits off,
--- silently matching the wrong role.
--- @param member table|nil
--- @return table list of role id strings
function Discord.rolesFromMember(member)
    if type(member) ~= 'table' or type(member.roles) ~= 'table' then
        return {}
    end

    local roles = {}

    for index = 1, #member.roles do
        local role = member.roles[index]
        if type(role) == 'string' and role ~= '' then
            roles[#roles + 1] = role
        end
    end

    return roles
end

--- The user id on one guild-member payload, or nil when the payload has none.
---
--- A member with no `user` happens: Discord omits it on some gateway-sourced
--- shapes, and a row keyed on nil would be worse than a row skipped.
function Discord.userIdFromMember(member)
    if type(member) ~= 'table' or type(member.user) ~= 'table' then
        return nil
    end

    local id = member.user.id
    if type(id) ~= 'string' or id == '' then return nil end

    return id
end

--- The pagination cursor for the next page: the highest user id on this one.
---
--- `GET /guilds/{id}/members` returns members ordered by user id ascending and
--- takes `after` to continue. Comparing as strings would be wrong -- snowflakes
--- vary in length -- so compare by length first, then lexically, which orders
--- decimal numerals correctly without converting to a float.
--- @param members table list of member payloads
--- @return string|nil cursor, nil when the page is empty
function Discord.cursorFrom(members)
    local highest = nil

    for index = 1, #members do
        local id = Discord.userIdFromMember(members[index])

        if id then
            if not highest
                or #id > #highest
                or (#id == #highest and id > highest)
            then
                highest = id
            end
        end
    end

    return highest
end

--- Turns a page of members into rows ready for the database.
--- @return table list of { discordId = string, roles = table }
function Discord.rowsFrom(members)
    local rows = {}

    for index = 1, #members do
        local member = members[index]
        local id = Discord.userIdFromMember(member)

        if id then
            rows[#rows + 1] = { discordId = id, roles = Discord.rolesFromMember(member) }
        end
    end

    return rows
end

--- Is the sync configured at all?
---
--- Takes the config rather than reading it, so this is testable and so the
--- caller decides what "configured" is scoped to.
function Discord.isConfigured(config)
    return type(config) == 'table'
        and type(config.token) == 'string' and config.token ~= ''
        and type(config.guildId) == 'string' and config.guildId ~= ''
end

-- -----------------------------------------------------------------------------
-- HTTP. Natives from here down.
-- -----------------------------------------------------------------------------

local function config()
    return FredPD.Config.server.discord
end

--- One GET against the Discord API.
---
--- Resolves to `status, decodedBody`. A request that never calls back would
--- otherwise park this coroutine forever, so the timeout resolves it instead --
--- as a failure, which means the rows age rather than being refreshed.
--- @return number status, table|nil body
local function get(path)
    local request = promise.new()
    local settled = false

    local function settle(status, body)
        if settled then return end
        settled = true
        request:resolve({ status = status, body = body })
    end

    PerformHttpRequest(API .. path, function(status, body)
        local decoded = nil

        if body and body ~= '' then
            local ok, parsed = pcall(json.decode, body)
            if ok then decoded = parsed end
        end

        settle(status, decoded)
    end, 'GET', '', {
        ['Authorization'] = 'Bot ' .. config().token,
        ['Content-Type'] = 'application/json',
        ['User-Agent'] = 'FredPD (https://github.com/Admin-Chatterly/FredPD, ' .. FredPD.version .. ')',
    })

    SetTimeout(HTTP_TIMEOUT_MS, function() settle(0, nil) end)

    local result = Citizen.Await(request)
    return result.status, result.body
end

--- Describes a failed response without ever revealing the token or the body.
local function explain(status)
    if status == 401 then
        return 'the bot token in config/server.lua was rejected'
    elseif status == 403 then
        return 'the bot is not in the guild, or the Server Members intent is off'
    elseif status == 404 then
        return 'the guild id in config/server.lua does not match a guild the bot can see'
    elseif status == 0 then
        return 'Discord did not answer in time'
    end

    return ('Discord answered %d'):format(status)
end

--- A GET that retries once when Discord rate-limits it.
local function getWithBackoff(path)
    local status, body = get(path)

    if status == 429 then
        local retryAfter = type(body) == 'table' and tonumber(body.retry_after) or 1
        -- Discord's retry_after is seconds, and fractional. Round up, and cap
        -- it: a pathological value must not park the sync for an hour.
        Wait(math.min(math.ceil(retryAfter) * 1000 + 250, 30000))
        status, body = get(path)
    end

    return status, body
end

-- -----------------------------------------------------------------------------
-- Storage
-- -----------------------------------------------------------------------------

--- Writes role snapshots, stamping `synced_at` as now.
---
--- One transaction for the whole page: a partial refresh that left half the
--- guild fresh and half stale would be read as a permission change.
--- @param rows table list of { discordId, roles }
local function store(rows)
    if #rows == 0 then return 0 end

    local statements = {}

    for index = 1, #rows do
        statements[index] = {
            query = [[INSERT INTO fpd_discord_members (discord_id, roles, synced_at)
                      VALUES (?, ?, NOW())
                      ON DUPLICATE KEY UPDATE roles = VALUES(roles), synced_at = VALUES(synced_at)]],
            values = { rows[index].discordId, json.encode(rows[index].roles) },
        }
    end

    FredPD.Core.db.transaction(statements)
    return #rows
end

-- -----------------------------------------------------------------------------
-- The sync
-- -----------------------------------------------------------------------------

--- True when a token and a guild id are configured.
function Discord.enabled()
    return Discord.isConfigured(config())
end

--- Can the bot see the configured guild at all?
---
--- Used to tell a member-level 404 apart from a guild-level one. Cheap, and
--- only ever called on that path.
function Discord.guildIsVisible()
    local status = getWithBackoff(('/guilds/%s'):format(config().guildId))
    return status == 200
end

--- The guild's roles, as a list of { id, name }, highest position first.
---
--- Setup prints these so an operator can pick the role that will grant
--- administration. Ordering by position puts the roles that mean something --
--- staff, command -- at the top, and `@everyone` at the bottom where it belongs.
--- @return table|nil roles, nil on failure
function Discord.guildRoles()
    if not Discord.enabled() then return nil end

    local status, body = getWithBackoff(('/guilds/%s/roles'):format(config().guildId))

    if status ~= 200 or type(body) ~= 'table' then
        print(('[fredpd] discord: could not read the guild roles -- %s'):format(explain(status)))
        return nil
    end

    local roles = {}

    for index = 1, #body do
        local role = body[index]

        if type(role) == 'table' and type(role.id) == 'string' then
            roles[#roles + 1] = {
                id = role.id,
                name = tostring(role.name or role.id),
                position = tonumber(role.position) or 0,
            }
        end
    end

    table.sort(roles, function(left, right) return left.position > right.position end)

    return roles
end

--- Refreshes one member, on connect.
---
--- A player who is not in the guild is not an error: they hold no roles, which
--- is stored as an empty list so the absence is a fact with a timestamp rather
--- than a missing row indistinguishable from a sync that never ran.
--- @param force boolean|nil ignore the cooldown; setup needs roles right now
--- @return boolean ok
function Discord.refreshOne(discordId, force)
    if not Discord.enabled() then return false end

    local last = lastRefreshedAt[discordId]
    if not force and last and (os.time() - last) < CONNECT_COOLDOWN_SECONDS then
        return true
    end

    local status, body = getWithBackoff(
        ('/guilds/%s/members/%s'):format(config().guildId, discordId)
    )

    if status == 404 then
        -- 404 means two different things on this endpoint: "this user is not in
        -- the guild" and "this guild is not one the bot can see". Storing an
        -- empty role list for the second would be catastrophic in a quiet way:
        -- a kicked bot or a mistyped guild id would give every connecting
        -- player a *fresh* row saying they hold nothing, so the staleness tiers
        -- in spec 4.2 would never fire and the outage would look like a healthy
        -- sync of a department where nobody has any roles.
        --
        -- One extra call, only on this path, tells the two apart.
        if not Discord.guildIsVisible() then
            print(('[fredpd] discord: %s'):format(explain(404)))
            return false
        end

        -- Genuinely not in the guild. An empty list with a timestamp is a fact;
        -- a missing row is indistinguishable from a sync that never ran.
        store({ { discordId = discordId, roles = {} } })
        lastRefreshedAt[discordId] = os.time()
        return true
    end

    if status ~= 200 then
        print(('[fredpd] discord: could not refresh a member -- %s'):format(explain(status)))
        return false
    end

    store({ { discordId = discordId, roles = Discord.rolesFromMember(body) } })
    lastRefreshedAt[discordId] = os.time()
    return true
end

--- Empties the roles of everybody the walk did not see.
---
--- A member who was kicked, banned or left is simply absent from the member
--- list, so nothing upserts their row and it keeps its old roles while its
--- `synced_at` ages. The staleness tiers narrow what they may *change*, but
--- neither tier blocks reads -- so an officer removed from Discord mid-shift
--- would keep reading files for as long as they stayed connected.
---
--- Only safe after a walk that reached the end of the guild. A walk that failed
--- or hit MAX_PAGES has not enumerated anybody, and clearing on that would
--- revoke the whole department over one bad response.
---
--- This still honours spec 4.2: a complete enumeration that did not contain
--- someone *is* Discord telling us they hold nothing here.
--- @param startedAt string database timestamp taken before the walk
local function clearMembersNotSeenSince(startedAt)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_discord_members
             SET roles = '[]', synced_at = NOW()
           WHERE synced_at < ? AND roles <> '[]']],
        { startedAt }
    )
end

--- Refreshes the whole guild, page by page.
--- @return number|nil members refreshed, nil on failure
function Discord.refreshAll()
    if not Discord.enabled() then return nil end

    -- The database's clock, not FXServer's: `store` stamps rows with `NOW()`,
    -- and comparing those against a local `os.time()` would misjudge anyone
    -- whose row was written during the walk whenever the two clocks disagree.
    local startedAt = FredPD.Core.db.scalar('SELECT NOW(3)')

    local after = nil
    local total = 0
    local walkedToTheEnd = false

    for _ = 1, MAX_PAGES do
        local path = ('/guilds/%s/members?limit=%d'):format(config().guildId, PAGE_SIZE)
        if after then path = path .. '&after=' .. after end

        local status, body = getWithBackoff(path)

        if status ~= 200 or type(body) ~= 'table' then
            print(('[fredpd] discord: role sync failed -- %s'):format(explain(status)))
            return nil
        end

        if #body == 0 then
            walkedToTheEnd = true
            break
        end

        total = total + store(Discord.rowsFrom(body))

        -- A page shorter than the limit is the last one. Checking the cursor as
        -- well means a page of members Discord sent without a `user` object
        -- ends the walk instead of requesting the same page forever -- but that
        -- case has *not* enumerated the guild, so it must not sweep.
        local cursor = Discord.cursorFrom(body)

        if #body < PAGE_SIZE then
            walkedToTheEnd = true
            break
        end

        if not cursor then break end

        after = cursor
    end

    if walkedToTheEnd and startedAt then
        local departed = clearMembersNotSeenSince(startedAt)

        if departed > 0 then
            print(('[fredpd] discord: %d member(s) are no longer in the guild and now hold nothing')
                :format(departed))
        end
    end

    return total
end

--- Refreshes now, then every `refreshMinutes`.
---
--- Started from `main.lua` at boot. The first pass is what turns a freshly
--- configured server into one where permissions work, so its result is printed.
function Discord.start()
    if not Discord.enabled() then
        print('[fredpd] discord: no token or guild id in config/server.lua -- nobody will have any permissions.')
        return
    end

    CreateThread(function()
        while true do
            local refreshed = Discord.refreshAll()

            if refreshed then
                print(('[fredpd] discord: %d members synced'):format(refreshed))

                -- Defined at the bottom of main.lua, which loads after this
                -- file. The thread only runs on a later tick so it is always
                -- there by now, but a nil call here would take the sync down
                -- permanently, and that is too much to stake on load order.
                if FredPD.onDiscordChange then
                    FredPD.onDiscordChange()
                end
            end

            Wait(math.max(tonumber(config().refreshMinutes) or 10, 1) * 60 * 1000)
        end
    end)
end

FredPD.Core.discord = Discord
