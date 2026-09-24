--- Sessions (spec 4.1, 4.6, invariant 1).
---
--- A session is what the server knows about a connected player: their Discord
--- identity, their bound character, their agency, and the permissions those
--- Discord roles currently grant.
---
--- Everything authoritative about an officer comes from here, never from route
--- input. A handler reads `session.discordId`; it never reads `input.officerId`.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Session = {}

--- server id -> session
local sessions = {}

--- The ESX job that grants `patrol_basic`-equivalent access while Discord is
--- not configured (spec 4.3, config/server.lua `discord.localJobFallback`).
--- `''` and `nil` both mean "off": the server refuses everyone, which is the
--- behaviour before this existed.
local function fallbackJob()
    local configured = FredPD.Config.server.discord.localJobFallback
    if type(configured) ~= 'string' or configured == '' then return nil end

    return configured
end

--- True when the job fallback applies to this character at all: Discord is
--- not configured, a fallback job is set, and this character holds it.
--- Never true on a server with Discord configured -- invariant 2 is
--- untouched for every server this fallback is not built for.
local function usingJobFallback(character)
    if FredPD.Core.discord.enabled() then return false end

    local job = fallbackJob()
    return job ~= nil and character.job == job
end

--- Creates the roster row a job-fallback session needs to write anything
--- (records, custody, evidence -- all foreign-key to `fpd_officers.id`).
--- Keyed on the ESX job rather than a Discord role, because there is no role
--- to key it on: the whole point of this path is a server that has not
--- configured Discord at all.
local function provisionFallbackOfficer(discordId, character)
    local agency = FredPD.Config.server.agency

    FredPD.Core.db.execute(
        [[INSERT INTO fpd_agencies (id, name, short_name, accent_color)
          VALUES (?, ?, ?, ?)
          ON DUPLICATE KEY UPDATE name = VALUES(name), short_name = VALUES(short_name)]],
        { agency.id, agency.name, agency.shortName, agency.accentColor or '#1b4f9c' }
    )

    -- `ON DUPLICATE KEY UPDATE active = 1` rather than an INSERT and a
    -- separate branch for "exists but deactivated": `uq_fpd_officers_discord_agency`
    -- means the plain INSERT this started as would fail outright on a row an
    -- administrator had deactivated, and reactivating it is the right answer
    -- either way -- the identifier and name it already carries are left
    -- alone, same as everywhere else a roster row is reactivated rather than
    -- rewritten.
    FredPD.Core.db.execute(
        [[INSERT INTO fpd_officers (discord_id, agency_id, identifier, name)
          VALUES (?, ?, ?, ?)
          ON DUPLICATE KEY UPDATE active = 1]],
        { discordId, agency.id, character.identifier, character.firstName .. ' ' .. character.lastName }
    )
end

--- A free callsign in the configured format (config `roster`), or nil when
--- the format cannot produce one. Read at call time: `personnel/service.lua`
--- loads after this file.
local function generateCallsign(agencyId)
    local roster = FredPD.Config.server.roster or {}
    local personnel = FredPD.Modules and FredPD.Modules.personnel
    if not personnel then return nil end

    local taken = {}
    local rows = FredPD.Core.db.query(
        'SELECT callsign FROM fpd_officers WHERE agency_id = ? AND callsign IS NOT NULL',
        { agencyId }) or {}
    for index = 1, #rows do taken[rows[index].callsign] = true end

    return personnel.nextCallsign(
        roster.callsignFormat or '{prefix}-{n}',
        roster.callsignPrefix or FredPD.Config.server.agency.shortName,
        roster.callsignStart or 101,
        taken)
end

--- Gives an officer with no callsign a generated one. Without a callsign an
--- officer never reaches the unit board (`fpd_units.callsign` is NOT NULL),
--- and nothing in the interface used to set one.
---
--- `callsign IS NULL` in the UPDATE, so a callsign a supervisor set in the
--- meantime is never overwritten. Two officers opening at the same instant can
--- draw the same number; that is a label clash a supervisor can fix, not an
--- integrity problem, and it is not worth a lock.
local function ensureCallsign(officer)
    if type(officer.callsign) == 'string' and officer.callsign ~= '' then return end

    local roster = FredPD.Config.server.roster or {}
    if roster.callsignFormat == false then return end

    local callsign = generateCallsign(officer.agency_id)
    if not callsign then
        print(('[fredpd] roster: could not generate a callsign for officer %d -- check roster.callsignFormat.')
            :format(officer.id))
        return
    end

    local changed = FredPD.Core.db.execute(
        'UPDATE fpd_officers SET callsign = ? WHERE id = ? AND callsign IS NULL',
        { callsign, officer.id })

    if changed and changed > 0 then
        officer.callsign = callsign
        print(('[fredpd] roster: officer %d is now %s.'):format(officer.id, callsign))
        FredPD.Core.audit.write({
            action = 'personnel.callsign.generated',
            agencyId = officer.agency_id,
            subjectType = 'officer',
            subjectId = tostring(officer.id),
            detail = { callsign = callsign },
        })
    end
end

--- Creates the roster row for an officer whose Discord roles grant something
--- in this agency but who has never opened FredPD before (config `roster`).
---
--- The grant is still Discord's (invariant 2): nothing here adds a
--- permission, and an officer whose roles map to nothing is refused exactly
--- as before. What it removes is a database row somebody had to type by hand
--- for every officer after the first.
---
--- `INSERT IGNORE` on `uq_fpd_officers_discord_agency`: an officer an
--- administrator deactivated keeps their inactive row and stays refused.
--- Auto-provisioning never reactivates anybody.
---
--- @return string|nil reason the officer was not provisioned, for the console
local function autoProvisionOfficer(discordId, character)
    local roster = FredPD.Config.server.roster or {}
    if roster.autoProvision == false then return 'auto-provision is off (roster.autoProvision)' end
    if not FredPD.Core.discord.enabled() then return 'Discord is not configured' end

    local requiredJob = roster.requireJob
    if type(requiredJob) == 'string' and requiredJob ~= '' and character.job ~= requiredJob then
        return ('this character does not hold the "%s" job (roster.requireJob)'):format(requiredJob)
    end

    local agencyId = FredPD.Config.server.agency.id

    -- Cheapest question first. A deactivated officer keeps hitting this on
    -- every route call (a failed open is not cached), and must cost one
    -- indexed lookup, not a role computation and a roster scan.
    local existing = FredPD.Core.db.single(
        'SELECT active FROM fpd_officers WHERE discord_id = ? AND agency_id = ? LIMIT 1',
        { discordId, agencyId })
    if existing then return 'a deactivated roster row exists for them' end

    -- A snapshot too old to trust for a sensitive action is too old to put
    -- somebody on the roster with (spec 4.2): they may have lost the role
    -- while sync was down.
    local _, age = FredPD.Core.perms.memberRoles(discordId)
    if age == nil or age > FredPD.Config.server.discord.sensitiveStaleAfterSeconds then
        return 'their Discord role snapshot is missing or stale'
    end

    local permissions = FredPD.Core.perms.effectiveFor(discordId, agencyId)
    if next(permissions) == nil then
        return 'their Discord roles map to no group in this agency (Administration > Role map)'
    end

    local agencyRow = FredPD.Core.db.single('SELECT id FROM fpd_agencies WHERE id = ?', { agencyId })
    if not agencyRow then return 'the agency does not exist yet -- run the setup first' end

    local callsign = generateCallsign(agencyId)
    local inserted = FredPD.Core.db.execute(
        [[INSERT IGNORE INTO fpd_officers (discord_id, agency_id, identifier, name, callsign)
          VALUES (?, ?, ?, ?, ?)]],
        { discordId, agencyId, character.identifier,
          character.firstName .. ' ' .. character.lastName, callsign }
    )

    if not inserted or inserted == 0 then return 'the roster insert changed nothing' end

    print(('[fredpd] roster: added %s %s (discord %s) to the roster as %s.')
        :format(character.firstName, character.lastName, discordId, tostring(callsign)))

    -- Invariant 11: binding a Discord account and a character to the agency is
    -- exactly the fact an internal-affairs reader needs to find later.
    FredPD.Core.audit.write({
        action = 'personnel.roster.provisioned',
        discordId = discordId,
        agencyId = agencyId,
        subjectType = 'officer',
        detail = { identifier = character.identifier, callsign = callsign },
    })

    return nil
end

--- Builds a session for a connected player, or returns nil with a reason.
---
--- @param src number server id
--- @return table|nil session
--- @return string|nil reason
function Session.open(src)
    local framework = FredPD.Bridge.framework

    -- The client sees one generic "not signed on" message whatever the reason
    -- (invariant 6 -- the four internal reasons below are not user-facing
    -- text). Without this, "no session" was undiagnosable from the console:
    -- an operator watching a player fail to open FredPD had no way to tell
    -- "no discord identifier" apart from "not in the roster" apart from "on
    -- the wrong character" -- three different fixes, one silent nil.
    local function refuse(reason)
        print(('[fredpd] session refused for %s: %s'):format(GetPlayerName(src) or tostring(src), reason))
        return nil, reason
    end

    local discordId = framework.getDiscordId(src)
    if not discordId then
        return refuse('no_discord: no "discord" identifier on this connection -- Discord Rich Presence/Game Activity must be on and linked')
    end

    local character = framework.getCharacter(src)
    if not character then
        return refuse('no_character: the framework has no character loaded for this player yet')
    end

    -- The roster decides which character may open FredPD for which agency. A
    -- Discord user holds one bound character per agency, so agency access
    -- cannot be used from a criminal alt (spec 4.1).
    local officer = FredPD.Core.db.single(
        [[SELECT id, agency_id, callsign, name, identifier, active, superuser
            FROM fpd_officers
           WHERE discord_id = ? AND active = 1
           LIMIT 1]],
        { discordId }
    )

    local jobFallback = usingJobFallback(character)

    if not officer and jobFallback then
        -- Discord is not configured, so there is no role to bind a roster
        -- row to -- provisioning one here is what lets this character open
        -- FredPD at all, rather than requiring an operator to run
        -- `fredpd_superuser` from the console before anyone can see the
        -- interface work.
        provisionFallbackOfficer(discordId, character)

        officer = FredPD.Core.db.single(
            [[SELECT id, agency_id, callsign, name, identifier, active, superuser
                FROM fpd_officers
               WHERE discord_id = ? AND active = 1
               LIMIT 1]],
            { discordId }
        )
    end

    local notProvisioned
    if not officer and not jobFallback then
        notProvisioned = autoProvisionOfficer(discordId, character)

        if not notProvisioned then
            officer = FredPD.Core.db.single(
                [[SELECT id, agency_id, callsign, name, identifier, active, superuser
                    FROM fpd_officers
                   WHERE discord_id = ? AND active = 1
                   LIMIT 1]],
                { discordId }
            )
        end
    end

    if not officer then
        return refuse(('not_personnel: discord_id %s has no active row in fpd_officers%s'):format(
            discordId, notProvisioned and (' and was not added: ' .. notProvisioned) or ''))
    end

    if officer.identifier and officer.identifier ~= character.identifier then
        return refuse(('wrong_character: fpd_officers is bound to %s, this character is %s')
            :format(officer.identifier, character.identifier))
    end

    -- After the binding check, so a refused open changes nothing.
    ensureCallsign(officer)

    -- A permanent grant made once from the console (spec 4.3, migration
    -- 0022). It bypasses Discord entirely rather than widening what a live
    -- role snapshot says: re-deriving it from Discord every open would make
    -- the recovery path exactly as fragile as whatever it exists to recover
    -- from -- an unreachable bot, an expired token, a `fpd_discord_members`
    -- table nothing has ever populated on a development server. Checked
    -- ahead of the job fallback below: a superuser grant is always the
    -- stronger answer, on a server with Discord configured or without it.
    local isSuperuser = officer.superuser == 1 or officer.superuser == true

    local roles, snapshotAge
    local permissions

    if isSuperuser then
        permissions = { ['*'] = true }
    elseif jobFallback then
        -- `patrol_basic`'s own permission set, asked of the model rather
        -- than restated here -- a second list would drift from the group
        -- the moment somebody edited one and not the other. Never more than
        -- that: this is a way to see the interface work without standing up
        -- Discord first, not a way around invariant 2 for a real deployment.
        permissions = FredPD.Core.perms.permissionsOf('patrol_basic') or {}
    else
        roles, snapshotAge = FredPD.Core.perms.memberRoles(discordId)
        permissions = FredPD.Core.perms.effectiveFor(discordId, officer.agency_id)
    end

    local session = {
        src = src,
        discordId = discordId,
        officerId = officer.id,
        agencyId = officer.agency_id,
        callsign = officer.callsign,
        name = officer.name or (character.firstName .. ' ' .. character.lastName),
        identifier = character.identifier,
        superuser = isSuperuser,
        -- Neither carries a live Discord snapshot to go stale (spec 4.2's
        -- outage policy is about a snapshot going old, and there is none
        -- here to begin with) -- `isStale`/`isReadOnly` exempt both.
        localFallback = (not isSuperuser) and jobFallback or false,
        roleCount = roles and #roles or 0,
        -- Stored as *when* the snapshot was taken, not how old it was at open.
        -- An age frozen at open never grows, so the outage policy below would
        -- never fire for anyone already connected -- which is exactly the
        -- window a gateway outage opens (spec 4.2). Left nil for a superuser
        -- or job-fallback session: there is no snapshot to go stale, by
        -- design.
        snapshotAt = (not isSuperuser and not jobFallback and snapshotAge)
            and (os.time() - snapshotAge) or nil,
        permissions = permissions,
        openedAt = os.time(),
    }

    sessions[src] = session
    return session, nil
end

--- The session for a server id, opening one on first use.
function Session.get(src)
    local existing = sessions[src]
    if existing then return existing end

    return (Session.open(src))
end

--- Updates the callsign on an officer's open session, if they have one.
--- Called after a supervisor edits the roster, so the change reaches the unit
--- board on its next pass rather than at the officer's next reconnect.
function Session.setCallsign(officerId, callsign)
    for _, session in pairs(sessions) do
        if session.officerId == officerId then session.callsign = callsign end
    end
end

function Session.drop(src)
    sessions[src] = nil
end

--- Recomputes permissions for every open session.
---
--- Called when the gateway pushes a Discord role change, and when an
--- administrator edits the role map. An open MDT loses pages the moment a role
--- is removed (spec 4.2), which only works because this exists.
function Session.refreshAll()
    for src, session in pairs(sessions) do
        -- Re-read rather than trusted from `Session.open`: a superuser flag
        -- granted or revoked from the console while this officer is
        -- connected has to take effect the same way every other permission
        -- change does (spec 4.2) -- immediately, with no reconnect needed.
        local officer = FredPD.Core.db.single(
            'SELECT superuser, callsign FROM fpd_officers WHERE id = ?', { session.officerId }
        )
        session.superuser = officer ~= nil and (officer.superuser == 1 or officer.superuser == true)
        -- Same reason: a callsign a supervisor changes takes effect without a
        -- reconnect. The unit board picks it up on its next pass.
        if officer then session.callsign = officer.callsign end

        if session.superuser then
            session.permissions = { ['*'] = true }
            session.snapshotAt = nil
        elseif session.localFallback then
            -- No role to re-derive this from -- Discord being unconfigured
            -- is what put it here, and that has not changed mid-session.
            session.permissions = FredPD.Core.perms.permissionsOf('patrol_basic') or {}
            session.snapshotAt = nil
        else
            session.permissions = FredPD.Core.perms.effectiveFor(session.discordId, session.agencyId)
            local _, age = FredPD.Core.perms.memberRoles(session.discordId)
            session.snapshotAt = age and (os.time() - age) or nil
        end

        FredPD.Core.push.toSession(src, 'fredpd:permissions', {
            modules = Session.allowedModules(session),
        })
    end
end

--- How old this session's permission snapshot is, right now.
---
--- Returns nil when the gateway has never seen this member, which every caller
--- below treats as maximally stale: we know nothing about their roles.
function Session.snapshotAge(session)
    if session.snapshotAt == nil then return nil end

    return os.time() - session.snapshotAt
end

--- True when the snapshot is too old to trust for a sensitive action
--- (spec 4.2). Degrades toward less access, never toward more.
---
--- A superuser session has no snapshot to go stale: its grant is a database
--- flag, not a live role, so the outage policy this guards against does not
--- apply to it (spec 4.3). Neither does a job-fallback session's -- it was
--- never derived from a Discord snapshot to begin with, and the outage
--- policy is a rule about roles going stale, not about the fallback itself.
function Session.isStale(session)
    if session.superuser or session.localFallback then return false end

    local age = Session.snapshotAge(session)
    if age == nil then return true end

    return age > FredPD.Config.server.discord.sensitiveStaleAfterSeconds
end

--- True when the snapshot is old enough that the session may only read
--- (spec 4.2, second tier). A gateway that has been down for hours must not
--- leave officers writing records against role data nobody can vouch for.
--- Exempts a superuser or job-fallback session for the same reason
--- `isStale` does.
function Session.isReadOnly(session)
    if session.superuser or session.localFallback then return false end

    local age = Session.snapshotAge(session)
    if age == nil then return true end

    return age > FredPD.Config.server.discord.readOnlyAfterSeconds
end

--- Which modules this session may open, for the NUI's module rail.
---
--- The list is derived from permissions on the server. The UI draws what it is
--- given and decides nothing (invariant 4).
function Session.allowedModules(session)
    local modules = {}
    local pages = {
        records = 'page.records',
        dispatch = 'page.dispatch',
        evidence = 'page.evidence',
        lab = 'page.lab',
        intel = 'page.intel',
        surveillance = 'page.surveillance',
        court = 'page.court',
        personnel = 'page.personnel',
        booking = 'page.booking',
        comms = 'page.comms',
        admin = 'page.admin',
    }

    -- Stable order, so the rail does not reshuffle between sessions.
    local order = {
        'records', 'dispatch', 'evidence', 'lab', 'intel', 'surveillance',
        'court', 'personnel', 'booking', 'comms', 'admin',
    }

    for index = 1, #order do
        local name = order[index]
        if FredPD.Core.perms.satisfies(session.permissions, pages[name]) then
            modules[#modules + 1] = name
        end
    end

    return modules
end

--- Every open session, for the push layer to filter.
function Session.all()
    return sessions
end

--- How many signed-on sessions in an agency could take a decision that needs
--- this permission, not counting `except` (spec 7.9.1).
---
--- The question the stand-in rules ask is "is anybody playing the åklagare
--- tonight?", and two kinds of session hold the grant without answering yes:
---
---   * **A superuser**, whose `'*'` satisfies every key. It is an
---     administrator's console grant, not a prosecutor; counting it would
---     mean an admin idling on the server blocked every stand-in decision.
---   * **A stale snapshot** (spec 4.2), which the route wrapper would refuse
---     for the very `sensitive` decision in question. A prosecutor who cannot
---     decide is not a prosecutor who is available.
function Session.countHolding(permission, agencyId, except)
    local count = 0

    for src, other in pairs(sessions) do
        if src ~= except
            and other.agencyId == agencyId
            and not other.superuser
            and not other.permissions['*']
            and FredPD.Core.perms.satisfies(other.permissions, permission)
            and not Session.isStale(other)
        then
            count = count + 1
        end
    end

    return count
end

AddEventHandler('playerDropped', function()
    Session.drop(source)
end)

FredPD.Core.session = Session
