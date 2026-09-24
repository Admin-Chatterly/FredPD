--- =============================================================================
--- FredPD configuration. **This is the only file you need to edit.**
--- =============================================================================
---
--- Fill in the three things under `discord` and `agency`, start the resource,
--- then run the setup command it prints. That is the whole install.
---
--- This file is listed in `server_scripts` and must never appear in `files {}`.
--- That is the difference between a secret the server holds and one every
--- player can download (invariant 7). Do not move these values into
--- `config/shared.lua`, which does reach clients.
---
--- If you run FredPD from a git clone rather than the release bundle, your
--- edited copy of this file carries a bot token: do not commit it.
---
--- Every value below can also be supplied as a `set` convar, which wins when
--- present. That is for hosts that template their configuration; you do not
--- need any convars for a normal install.

FredPD = FredPD or {}
FredPD.Config = FredPD.Config or {}

local function setting(convar, fallback)
    local value = GetConvar(convar, '')
    if value == '' then return fallback end
    return value
end

FredPD.Config.server = {
    -- -------------------------------------------------------------------------
    -- 1. Discord  (required)
    --
    -- Discord roles are the only thing that grants access in FredPD
    -- (invariant 2), so this is what makes the suite work at all.
    --
    -- Create the bot once:
    --   1. https://discord.com/developers/applications -> New Application
    --   2. Bot -> Reset Token -> copy it into `token` below
    --   3. Bot -> Privileged Gateway Intents -> enable SERVER MEMBERS INTENT
    --   4. Installation -> invite it to your guild (no permissions needed --
    --      it only reads the member list)
    --
    -- `guildId`: right-click your server in Discord -> Copy Server ID.
    -- Both need Developer Mode on: Settings -> Advanced -> Developer Mode.
    -- -------------------------------------------------------------------------
    discord = {
        token = setting('fredpd:discord_token', ''),
        guildId = setting('fredpd:discord_guild', ''),

        --- How often the whole member list is refreshed, in minutes.
        --- A role added or removed in Discord takes effect within this window
        --- without a restart. Joining the server refreshes that player at once,
        --- so this is the ceiling on how stale anyone's roles can be.
        refreshMinutes = 10,

        --- Outage policy (spec 4.2). Both tiers degrade toward *less* access:
        --- Discord going unreachable must never widen what anyone can do.
        ---
        --- Past this, sensitive actions (approvals, releases, deletions,
        --- intelligence and surveillance) are refused.
        sensitiveStaleAfterSeconds = 15 * 60,
        --- Past this, the session is read-only: nothing that changes state.
        readOnlyAfterSeconds = 6 * 60 * 60,

        --- A fallback for a server that has not filled in `token`/`guildId`
        --- above yet -- most often one being tried out locally before Discord
        --- is ever set up. FredPD's access model is Discord roles and nothing
        --- else (invariant 2), and this does not change that: it activates
        --- only when Discord is *not configured*, which is also the one case
        --- invariant 2 has nothing to check a role against. Without it, such
        --- a server has no way into the MDT at all short of running
        --- `fredpd_superuser` from the console for every officer by hand.
        ---
        --- While it is active, holding this ESX job grants exactly the
        --- `patrol_basic` group's permissions and nothing more -- enough to
        --- open records and see the interface work, never Administration.
        --- Set to `''` to turn it off and keep the old behaviour: an
        --- unconfigured server refuses everyone.
        localJobFallback = setting('fredpd:local_job_fallback', 'police'),
    },

    -- -------------------------------------------------------------------------
    -- 2. Your agency  (required)
    --
    -- Created by the setup command on first run. `id` is a short stable key
    -- used in the database and never shown to players; change it before you set
    -- up, not after.
    -- -------------------------------------------------------------------------
    agency = {
        id = 'lspd',
        name = 'Los Santos Police Department',
        shortName = 'LSPD',
        accentColor = '#1b4f9c',
    },

    --- Field actions on people and vehicles (ox_target).
    field = {
        --- How close, in metres, an officer must stand to check an ID or run
        --- the plate on a car. Checked on the server.
        range = 5.0,
    },

    --- The roster (spec 4.1, 7.22). Nobody should have to type a row into
    --- the database before a new officer can use FredPD.
    roster = {
        --- An officer whose Discord roles grant anything in this agency gets
        --- a roster row the first time they open FredPD. Their current
        --- character is bound to it, which is why `requireJob` exists.
        autoProvision = true,
        --- The ESX job the character must hold for that first bind, so a
        --- player cannot bind their criminal character by opening FredPD
        --- on it first. `''` turns the check off. Grants nothing (invariant 2).
        requireJob = setting('fredpd:roster_job', 'police'),
        --- Generated callsigns. `{prefix}` is `callsignPrefix`, `{n}` counts
        --- up from `callsignStart` to the first one nobody holds. Given to
        --- every officer who has none when they open FredPD. A supervisor
        --- can change it on the Personnel screen.
        callsignFormat = '{prefix}-{n}',
        callsignPrefix = 'LSPD',
        callsignStart = 101,
    },

    -- -------------------------------------------------------------------------
    -- 3. Everything below has a working default. Leave it alone unless you have
    --    a reason.
    -- -------------------------------------------------------------------------

    --- Default route rate limit, per session (spec 3.5). A route may set its own.
    rateLimit = {
        per = 30,
        window = 60,
    },

    --- The forensic lab (spec 8.7).
    ---
    --- How long an analysis takes, in real minutes, counted from the moment an
    --- analyst starts it at the lab terminal. The due time is written to the
    --- database, so timers survive a restart and nobody can shorten one.
    ---
    --- Priority is a multiplier on whatever is set here: `routine` is the full
    --- time, `expedited` half of it and `urgent` a quarter. An analysis that is
    --- not listed takes 30 minutes.
    ---
    --- Longer is better than shorter. The wait is the mechanic -- it is what
    --- makes a lab request a decision about which items matter rather than a
    --- button pressed on everything collected.
    frihet = {
        --- Standing in for the åklagare and the domare (spec 7.9.1). When
        --- nobody holding `frihet.anhallande` is signed on, a session holding
        --- `frihet.fallback.aklagare` (supervisor, by the seed) may anhålla
        --- and send the framställan; when nobody holding `frihet.haktning` is
        --- on, `frihet.fallback.domare` (command) may decide the häktning.
        --- Logged as a stand-in decision on the custody record and in the
        --- audit trail. Set to false to leave every decision to the real role.
        fallback = true,
    },

    lab = {
        --- The automatic lab. When no lab analyst is signed on, a request
        --- waiting longer than `autoStartAfterSeconds` is taken on by the
        --- lab itself and finished when its time is up, so a case does not
        --- stall because nobody is playing the analyst tonight. An analyst's
        --- own work their clock has run out on is finished for them
        --- `autoCompleteGraceSeconds` later. The turnaround below still
        --- applies either way; set `auto = false` to leave it all to people.
        auto = true,
        autoStartAfterSeconds = 120,
        autoCompleteGraceSeconds = 900,

        analysisMinutes = {
            dna = 45,
            print_comparison = 20,
            print_search = 25,
            ballistics = 40,
            gsr = 15,
            drug_id = 10,
        },
    },

    --- What a player is wearing (spec 3.8, 8.2).
    ---
    --- Read from whichever clothing resource you run -- illenium-appearance,
    --- fivem-appearance and esx_skin are tried in that order without any
    --- configuration. Set `resource` (and `getters`, if your fork renamed the
    --- export) only if you run something else; naming one replaces the list
    --- rather than adding to it.
    ---
    --- `gloves` is the part that matters to section 8, and it is the part
    --- nobody can fill in for you. Gloves are what turn a fingerprint into a
    --- glove mark, and GTA has no "wearing gloves" flag: gloves are drawn as
    --- part of the arms, so the only way to tell is to know which arms
    --- drawables are the gloved ones. That is a property of the clothing *your*
    --- server ships, so it lives here and not in the code.
    ---
    --- It ships commented out, and FredPD keeps no built-in list to fall back
    --- on, because the two mistakes do not cost the same. Leaving a gloved drawable
    --- out is the cheap one: that touch leaves a fingerprint, which an
    --- investigator can still work with. Listing a drawable that is *not*
    --- gloved is the expensive one: every touch in that garment leaves a glove
    --- mark, and the fingerprints those touches should have left never exist --
    --- and a fingerprint is the only trace that reaches a fingerprint index
    --- search, the one analysis that can put a name to an offender nobody has
    --- named yet. A list guessed by us would make the expensive mistake on
    --- every server at once, so there is no guess here.
    ---
    --- Until you fill it in, every touch leaves a fingerprint and nobody ever
    --- leaves a glove mark. The resource prints that on every start rather than
    --- leaving you to wonder.
    ---
    --- To fill it in: on your own server, open your clothing menu and step
    --- through the arms drawables (clothing component 3), noting the ids that
    --- put gloves on the hands. Key them by ped model name, then by drawable
    --- id. Do it once per ped model -- `mp_m_freemode_01` and
    --- `mp_f_freemode_01` have different component 3 tables, so one list copied
    --- to both is wrong for at least one of them -- and do it again if you add
    --- a clothing pack, EUP or add-on DLC clothing, where the numbering is your
    --- pack's and not the base game's. A ped model that is not listed leaves
    --- fingerprints and never glove marks.
    appearance = {
        -- gloves = {
        --     -- The arms drawable ids you checked, per ped model. Nothing is
        --     -- filled in here because nothing here can know your clothing.
        --     ['mp_m_freemode_01'] = {},
        --     ['mp_f_freemode_01'] = {},
        -- },
    },

    --- Evidence in the world (spec 8).
    ---
    --- The grid's own numbers -- cell size, how far traces are streamed, how
    --- long each type lives and how fast it decays -- all have working defaults
    --- in `server/modules/forensics/service.lua`, and anything you put in this
    --- section is merged over them, two levels deep: setting one item name below
    --- leaves the rest of the defaults alone.
    ---
    --- `destroyItems` is the part most servers end up touching. It maps each
    --- destruction action to the ox_inventory item it spends, and the item
    --- names are a property of your item list rather than of FredPD:
    ---
    ---   wipe   -- the kit spent wiping a surface down
    ---   weapon -- the kit spent cleaning a weapon (the same kit by default)
    ---   clean  -- the chemicals spent cleaning up a pool of blood
    ---
    --- The three names FredPD ships with are in `Forensics.defaults.destroyItems`
    --- in `server/modules/forensics/service.lua`, and that file is the only copy
    --- of them. Write a key here only for an action whose item you actually
    --- renamed: the merge is per key, so overriding `clean` leaves `wipe` and
    --- `weapon` on whatever the release ships -- including a release that
    --- renames one. Restating a name you did not change pins it silently.
    ---
    --- Washing your hands and picking your own casings up cost nothing and have
    --- no entry: they are not items you can fail to own.
    ---
    --- An action whose item your server does not have is refused every time, and
    --- the officer is told they have no item. If destruction never works, check
    --- those three names against your item list before overriding anything.
    ---
    --- `enabled` turns individual evidence types off (spec 8.2). Every type
    --- defaults to on; write only the ones you want off, and the rest are
    --- untouched by the same per-key merge as everything else here. A type
    --- turned off is never generated at all -- not created and hidden, not
    --- created and discarded, simply never written -- so a lighter or heavier
    --- scene is a config choice, not a code change:
    ---
    ---   print, glove_mark  -- fingerprints and the marks gloves leave instead
    ---   blood, bullet      -- from the server's own damage event, never a client claim
    ---   casing, magazine   -- from firing and reloading
    ---   gsr                -- gunshot residue on the shooter's hands
    ---   dna_touch          -- saliva/touch DNA from handling or consuming an item
    ---   drug_residue       -- from handling an item named in `drugItems` below
    ---   footwear           -- from walking through a blood trace already in the grid
    ---   tool_mark          -- from lockpicking or a forced entry
    ---   digital            -- reserved; nothing generates this yet in any FredPD release
    ---
    --- `tool_mark` needs a break-in or lockpicking script to call
    --- `fredpd_forensics`'s `toolUsed` export before it generates anything,
    --- whatever this says -- see `client/sensors.lua` in that resource. Turning
    --- it off is still worth doing if you never intend to write that bridge.
    forensics = {
        -- destroyItems = {
        --     clean = 'my_cleaning_chemicals',
        -- },
        -- enabled = {
        --     drug_residue = false,
        --     footwear = false,
        -- },

        --- Item names that leave drug residue rather than touch DNA when
        --- handled (spec 8.2) -- read by the `item_use` sensor once an
        --- ox_inventory bridge reports a use at all (`fredpd_forensics/client/
        --- bridges/inventory.lua`). Empty by default: which of your items are
        --- drugs is a property of your item list, and an item not named here
        --- still leaves touch DNA, which was the only outcome before this
        --- setting existed.
        -- drugItems = {
        --     ['baggie_cocaine'] = true,
        --     ['weed_bag'] = true,
        -- },

        --- The prop a type is drawn as, by type (8.1.6). A type with no entry
        --- here is drawn as a plain marker instead -- `models = {}` is the
        --- shipped default, deliberately: no prop is guessed at for you.
        ---
        --- GTA V has no built-in loose shell-casing object -- vanilla brass
        --- ejection is a particle effect, not a streamed prop -- so there is
        --- no stock model name for `casing` that ships with the base game.
        --- `ch_prop_ch_fib_01a` (Diamond Casino Heist DLC) is the operator's
        --- own pick; confirm it actually spawns in-game before relying on it,
        --- the same as any model named here -- a typo'd or wrong name fails
        --- to load rather than erroring loudly.
        models = {
            casing = 'ch_prop_ch_fib_01a',
        },
    },

    --- Dispatch: the unit board, the live map and the call queue (spec 7.16,
    --- 7.17, 7.18).
    ---
    --- Everything here has a working default in
    --- `server/modules/cad/service.lua` (`Cad.defaults`),
    --- `server/modules/cad/avl.lua` and `server/modules/cad/events.lua`, and
    --- anything you write below is merged over them two levels deep -- so
    --- setting one status in `welfareSeconds` leaves the rest alone.
    ---
    --- It ships commented out on purpose. A key written here is *pinned*: a
    --- later release that improves a default cannot reach a server that has a
    --- copy of the old one sitting in its configuration. That has bitten this
    --- project once already (`forensics.destroyItems`, above). Write a key only
    --- for a number you have actually decided to change.
    ---
    --- **Sign-on** (7.1). An officer becomes a unit on the board when the duty
    --- bridge says they are on duty; nothing in the MDT signs a unit on, because
    --- a unit row is a fact the server can see for itself.
    ---
    ---   dutyPollSeconds     How often duty is checked, and therefore the worst
    ---                       case between going on duty and appearing on the
    ---                       board. Default 15; five is the floor.
    ---   signOffGraceSeconds How long a unit keeps its place on the board after
    ---                       its officer disconnects. This is what lets a
    ---                       crashed officer reconnect to the same unit, on the
    ---                       same call, with the same time in status. Default
    ---                       300. Zero signs them off the moment they drop.
    ---   dutyRequired        Whether duty is required at all. Leave it true.
    ---                       Set it false only on a server with no duty concept:
    ---                       the duty bridge answers "off duty" when it cannot
    ---                       answer at all, so on such a server nobody would
    ---                       ever reach the board. With it off, any officer who
    ---                       may set a unit status is a unit while connected.
    ---
    --- **The welfare check** (7.16: a unit on scene too long).
    ---
    ---   welfareSeconds       Per unit status, in seconds. Only `on_scene` is
    ---                        set by default (1200), because that is the status
    ---                        where silence means something. Add `en_route` or
    ---                        `busy` if your agency wants the same prompt there.
    ---   welfareRepeatSeconds How long before the same unit is prompted about
    ---                        again. Default 600.
    ---
    --- **The call card and the queue.**
    ---
    ---   recommendLimit        How many units the card offers as "closest
    ---                         available". Default 3.
    ---   positionMaxAgeSeconds How old a position may be before the closest-unit
    ---                         recommendation flags it as a guess. Default 120.
    ---   broadcastMinutes      How long a broadcast stands when the dispatcher
    ---                         does not say. Default 720 -- a shift and a half.
    ---
    --- **The live map** (7.17, 3.6). The sweep costs nothing until somebody
    --- opens the map, so these matter only while one is open.
    ---
    ---   avlIntervalSeconds       Seconds between position pushes. Default 2,
    ---                            and clamped to 3.6's one-to-two second window
    ---                            whatever you write.
    ---   avlPersistEverySweeps    How often the positions are written to the
    ---                            database rather than only pushed. Default 5,
    ---                            so every ten seconds.
    ---   avlMoveThreshold         Metres a unit must move before the map is
    ---                            told. Default 2.0.
    ---   avlHeadingThreshold      Degrees it must turn, for the same reason.
    ---                            Default 10.0.
    ---   avlBoardTtlSeconds       How long a cached unit board stands without an
    ---                            explicit invalidation. Default 10; every write
    ---                            invalidates it, so this is a floor and not the
    ---                            mechanism.
    ---   avlWelfareIntervalSeconds Seconds between welfare passes. Default 30.
    ---
    --- **Plate reads** (7.18).
    ---
    ---   alprRetentionDays How long reads are kept. Default 30, which is also
    ---                     7.18's. The retention sweep enforces it (ADR-021);
    ---                     `retention.days.alprReads` below wins when set.
    cad = {
        -- dutyPollSeconds = 15,
        -- signOffGraceSeconds = 300,
        -- dutyRequired = true,
        -- welfareSeconds = {
        --     en_route = 15 * 60,
        -- },
    },

    --- Ordningsbot: the fixed-penalty citation (spec 7.11).
    ---
    --- How many days somebody has to pay before an `issued` citation reads as
    --- overdue. Written onto the citation at issue time, so changing this
    --- number here never moves the deadline on one already handed to
    --- somebody -- see migration 0024's header.
    ordningsbot = {
        paymentWindowDays = 30,

        --- Licence points (ADR-018). Each tariff line says how many points a
        --- citation under it adds to the named person's driving licence;
        --- points count while the citation is issued or paid and younger
        --- than `windowDays`. At `threshold` the licence reads as revoked
        --- (sv: återkallat) wherever an officer looks the person up. Nothing
        --- is written to another resource: this is the record, not a
        --- licence system.
        licence = {
            enabled = true,
            threshold = 12,
            windowDays = 365,
        },

        --- The catalogue written for an agency whose tariff is empty, at
        --- start. Amounts in whole currency units. An agency's command edits
        --- it in the MDT afterwards (`ordningsbot.tariff.edit`); this list is
        --- never re-applied over an edited tariff.
        defaultTariff = {
            { code = 'speeding_10', labelKey = 'ordningsbot.tariff.speeding_10', amount = 2000, points = 1 },
            { code = 'speeding_20', labelKey = 'ordningsbot.tariff.speeding_20', amount = 2800, points = 2 },
            { code = 'speeding_30', labelKey = 'ordningsbot.tariff.speeding_30', amount = 3600, points = 4 },
            { code = 'red_light', labelKey = 'ordningsbot.tariff.red_light', amount = 3000, points = 3 },
            { code = 'failure_to_yield', labelKey = 'ordningsbot.tariff.failure_to_yield', amount = 2000, points = 2 },
            { code = 'unsafe_overtaking', labelKey = 'ordningsbot.tariff.unsafe_overtaking', amount = 3000, points = 3 },
            { code = 'phone_driving', labelKey = 'ordningsbot.tariff.phone_driving', amount = 1500, points = 2 },
            { code = 'no_seatbelt', labelKey = 'ordningsbot.tariff.no_seatbelt', amount = 1500, points = 1 },
            { code = 'vehicle_defect', labelKey = 'ordningsbot.tariff.vehicle_defect', amount = 1000, points = 0 },
            { code = 'no_licence_carried', labelKey = 'ordningsbot.tariff.no_licence_carried', amount = 400, points = 0 },
            { code = 'parking', labelKey = 'ordningsbot.tariff.parking', amount = 800, points = 0 },
            { code = 'noise', labelKey = 'ordningsbot.tariff.noise', amount = 1500, points = 0 },
        },
    },

    --- Cameras (spec 7.19). CCTV cameras are `cctv_camera` placements set up
    --- in game; body-worn cameras are officers' issued `bodycam`; dash cameras
    --- are agency vehicles. `frameMs` is how often a body-worn or dash view is
    --- moved (per viewer, never broadcast); `maxWindowHours` is the longest a
    --- footage request may ask to look for.
    cameras = {
        frameMs = 250,
        maxWindowHours = 12,
    },

    --- Civilian mode (spec 7.29): a police front desk anybody may use (a
    --- `public_counter` placement, set up in game). `perDay` is how many
    --- reports one character may hand in over a day.
    civilian = {
        perDay = 5,
    },

    --- Discord role actions (ADR-022): hire, promote, demote and dismiss
    --- from the roster, as a Discord role change the gateway makes with a bot
    --- of its own. Off by default, and needs the gateway (3.7).
    ---
    --- `roles` lists the only roles that can be changed from FredPD, each a
    --- `hire` role (what makes somebody an officer; needs personnel.hire) or
    --- a `rank` (needs personnel.promote). The gateway keeps its own copy of
    --- the list (FREDPD_ROLE_ACTIONS_ALLOWED) and refuses anything else, so
    --- both must name the same ids. Never list an administration role here.
    roleActions = {
        enabled = false,
        roles = {
            -- { id = '123456789012345678', kind = 'hire' },
            -- { id = '223456789012345678', kind = 'rank' },
        },
    },

    --- Retention (spec 13.3, ADR-021): what is deleted, and when. Runs inside
    --- FXServer every `intervalMinutes`, the first time ten minutes after
    --- start. Days below a sweep's floor are raised to it (see
    --- `retention/service.lua`); `false` turns one sweep off. Every run writes
    --- one audit row saying what each sweep removed.
    retention = {
        enabled = true,
        intervalMinutes = 360,
        days = {
            queryLog = 365,
            -- alprReads = 30,   -- unset: `cad.alprRetentionDays` decides
            staleDrafts = 180,
            surveillanceSessions = 730,
            stops = 730,
            publicReports = 730,
            abandonedUploads = 1,
        },
    },

    --- Printing (spec 7.28, ADR-020). A paper copy is an ox_inventory item
    --- that must exist in your item list (docs/installation.sv.md, 11d); its
    --- metadata carries the document as printed, so whoever holds the paper
    --- can read it. A PDF needs the gateway (3.7).
    documents = {
        paperItem = 'fredpd_paper',
        -- The highest classification a paper copy may carry. A paper is read
        -- by whoever holds it, with no clearance and no audit, so anything
        -- above this, in a compartment, sealed or opened by break-glass is
        -- PDF-only (and a restricted PDF needs document.export.restricted).
        paperCeiling = 'internal',
    },

    --- Impound in the world (spec 7.15, ADR-016). "Impound" on a car through
    --- ox_target records the impound and takes the car off the street; the
    --- owner's garage shows it as out until it is released, when it is back
    --- in their garage.
    impound = {
        world = {
            --- Delete the car when it is impounded on the spot. Never with a
            --- player inside it.
            despawn = true,
            --- How close, in metres, the officer must be to the car.
            range = 8.0,
            --- What `esxData.vehicles.stored` is set to when a tow takes the
            --- car, and when it is released. Only a car the tow removed, whose
            --- garage row names the same model, is ever touched.
            ---
            --- 2 is a value esx_garage ignores: the car shows neither in the
            --- garage nor at its pound, so the owner cannot pay the ESX pound
            --- and drive off with a car FredPD still holds. Do not use 0 --
            --- that is "out", which most pounds hand back for a flat fee.
            --- Do not change it while cars are held: a release only hands a
            --- car back if its row still reads this value.
            storedWhileImpounded = 2,
            storedOnRelease = 1,
        },
    },

    --- Jail: a court sentence is served in the game (spec 7.20, ADR-017).
    ---
    --- When a domare enters a guilty verdict with a prison sentence, the
    --- person is handed to the police job's jail -- at once if they are on,
    --- or the next time their character loads. p_policejob's documented
    --- server export is `JailPlayer(source, { player, jail, fine, reason })`;
    --- `resource` and `export` name another jail that takes the same call.
    ---
    --- A Swedish sentence is months; the jail counts game minutes. The
    --- conversion is fixed onto the verdict when it is entered.
    jail = {
        enabled = true,
        resource = 'p_policejob',
        export = 'JailPlayer',
        --- Game minutes per month of the sentence.
        minutesPerMonth = 1,
        --- The shortest and longest time the jail is asked for, in minutes.
        --- Livstid is served as `maxMinutes`.
        minMinutes = 5,
        maxMinutes = 120,
    },

    --- Billing: a citation sends a real bill (spec 7.11, 3.8).
    ---
    --- Issuing an ordningsbot citation bills the person it names -- or, for a
    --- vehicle alone, its registered keeper -- through esx_billing, paid into
    --- the agency's society account: `society_<agency>` by default, or the
    --- name set for the agency in `societies`. It must be a `society_*`
    --- account -- esx_billing pays any other account to the bill's sender,
    --- who here is the issuing officer, so the bridge refuses one. When the bill leaves esx_billing's table the citation is
    --- marked paid by itself; voiding or contesting it withdraws the bill.
    --- `enabled = false`, or esx_billing not started, leaves every citation
    --- to be marked paid by hand as before.
    billing = {
        enabled = true,
        resource = 'esx_billing',
        --- esx_billing's own table, which is where a bill's id comes from and
        --- where its payment shows (the row is deleted when it is paid).
        table = 'billing',
        --- How often outstanding bills are checked for payment, in seconds.
        syncSeconds = 60,
    },

    --- The esx_society account each agency's funds live in, when it is not
    --- `society_<agency id>`. Used by the motor pool and by billing.
    -- societies = { lspd = 'society_police' },

    --- The gateway is a separate Node service for media, PDF rendering and
    --- scheduled jobs. None of that exists yet and FXServer never calls it, so
    --- it is off and you do not need to deploy anything (ADR-010). When it
    --- arrives, set `enabled = true` and give it a secret generated with
    --- `openssl rand -hex 32`.
    gateway = {
        enabled = false,
        url = setting('fredpd:gateway_url', 'http://127.0.0.1:3080'),
        secret = setting('fredpd:gateway_secret', ''),
        --- How long a signed request stays valid, in seconds (spec 3.7).
        replayWindow = 30,
        --- Where players' NUI reaches the gateway's media routes: the
        --- gateway's own `FREDPD_MEDIA_BASE_URL`, and the host the NUI was
        --- built with (`VITE_MEDIA_HOST`), or the CSP blocks every image.
        mediaUrl = setting('fredpd:gateway_media_url', 'http://127.0.0.1:3080'),
        --- How long a signed photo link works, in seconds. The gateway's own
        --- `FREDPD_MEDIA_TOKEN_TTL` bounds upload links; this bounds the
        --- download links FXServer signs itself (ADR-019).
        mediaLinkSeconds = 900,
    },

    --- Suggesting real citizens and vehicles while an officer is registering
    --- one, read straight from ESX's own tables (`server/bridges/framework.lua`
    --- explains why this is the one place FredPD reads another resource's
    --- schema directly instead of calling its exported API).
    ---
    --- The column names below are es_extended / ESX Legacy's -- the same
    --- framework every other bridge in this resource already assumes. If your
    --- server runs a fork that renamed one of these columns, change the name
    --- here; nothing else needs to know. Set `enabled = false` to turn the
    --- suggestions off everywhere and fall back to typing everything by hand,
    --- which is what FredPD did before this existed.
    esxData = {
        enabled = true,

        --- `users`, or whatever your fork calls the character table.
        characters = {
            table = 'users',
            identifier = 'identifier',
            firstName = 'firstname',
            lastName = 'lastname',
            dateOfBirth = 'dateofbirth',
            phone = 'phone_number',
        },

        --- `owned_vehicles`, or whatever your fork calls it.
        vehicles = {
            table = 'owned_vehicles',
            owner = 'owner',
            plate = 'plate',
            --- The column a vehicle's properties are stored in. On es_extended
            --- this is a JSON blob (`vehicleJson = true`) and the model comes
            --- out of it as whatever ESX itself stored -- usually a hash
            --- number, not a name (`Framework.searchOwnedVehicles` explains
            --- why FredPD does not try to resolve that further). A fork with
            --- a plain `model` column instead should set `vehicleJson = false`.
            vehicleColumn = 'vehicle',
            vehicleJson = true,
            --- The column saying whether a car is in its owner's garage. A tow
            --- sets it to `impound.world.storedWhileImpounded` and the release
            --- of that impound to `storedOnRelease`. nil leaves the table alone.
            stored = 'stored',
        },
    },
}
