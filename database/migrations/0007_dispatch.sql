-- 0007_dispatch.sql
--
-- Dispatch (CAD): calls, the unit board and AVL, beats, broadcasts and ALPR
-- (spec 7.16, 7.17, 7.18; milestone M4).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHAT A DISPATCH RECORD IS FOR, AND WHY THAT DECIDES THE SHAPE
-- =============================================================================
--
-- Everything else in FredPD is written after the fact by somebody with time to
-- think. A call is written *during* the event, by two people at once, and it is
-- read afterwards to answer three questions that are asked in public:
--
--   * How long did it take us to get there? (received -> dispatched -> en route
--     -> on scene, the five timestamps 7.16 names)
--   * Who was sent, and who had it? (`fpd_call_units`, with the lead unit)
--   * What were we told, and when? (`fpd_call_log`, append-only)
--
-- Two consequences run through every table below.
--
-- **A timestamp is never re-derived and never overwritten.** `dispatched_at` is
-- stamped once, when the call is first assigned, and stays there even if the
-- call is later re-dispatched to a second unit. A response-time report is the
-- arithmetic on these five columns, and a column that moves is a report that
-- changes its answer between two readings of the same call.
--
-- **The status and the timestamps must never disagree.** A call whose status is
-- `on_scene` with `on_scene_at` NULL is not a display bug: it is a call that
-- will be quoted in an inquiry as having had no arrival time. The CHECKs on
-- `fpd_calls` make each of those states impossible to store, rather than
-- something the service layer is trusted to remember on every path -- and the
-- service layer has four paths to `on_scene` (dispatcher, self-assign, the
-- status route, and the export in 11.2).
--
--
-- =============================================================================
-- WHY THERE IS NO POSITION ROUTE, AND WHERE POSITIONS COME FROM
-- =============================================================================
--
-- `fpd_units` holds a last known position (AVL, 7.17) and **no client ever
-- writes it**. The server holds every player's ped and reads
-- `GetEntityCoords` off it, the way `forensics/grid.lua` already does.
--
-- A route that let a client report its own position would be a client telling
-- the server where a police unit is, which is invariant 1 read backwards, and
-- the abuse is not theoretical: the same officer who is being asked why they
-- were not at the call they were dispatched to is the one who would be sending
-- the coordinates that answer it. A false alibi has to be impossible to write,
-- not merely against the rules.
--
-- So there is no position field in any route schema in this milestone, and the
-- columns below are written by the server's own sweep, at the 1-2 second
-- cadence 3.6 sets for sessions with the map open.
--
--
-- =============================================================================
-- THE PENDING QUEUE, WITHOUT A TABLE SCAN PER POLL
-- =============================================================================
--
-- 7.16 wants the pending queue "stacked by priority and age": every open call
-- for the agency, P1 first, oldest first within a priority. Written directly
-- that is
--
--     WHERE agency_id = ? AND status IN ('pending','dispatched','en_route','on_scene')
--     ORDER BY priority, received_at
--
-- and no index makes it cheap. An index on `(agency_id, status, priority,
-- received_at)` gives four separate ranges, one per status, which the optimizer
-- then has to merge and sort -- a filesort over every open call on every poll,
-- growing with the number of calls the server has *ever* taken, because closed
-- calls sit in the same ranges the scan walks past.
--
-- `queue_priority` is the fix and it is the same trick `fpd_record_seals`
-- (0005) uses for live seals: a stored generated column that is the priority
-- while the call is open and NULL once it is closed. Then
--
--     WHERE agency_id = ? AND queue_priority IS NOT NULL
--     ORDER BY queue_priority, received_at
--
-- reads `idx_fpd_calls_queue` forward from the first non-NULL entry and stops
-- when the page is full. No sort, and the cost does not depend on how many
-- calls have been cleared, because every cleared call collapses to one NULL
-- region at the front of the index that a single seek skips. The column is
-- generated rather than maintained by the module for the reason 0005 gives for
-- the phonetic columns: a flag the application sets is a flag some path forgets
-- to clear, and the path that forgets here leaves a cleared call sitting at the
-- top of the queue.
--
--
-- =============================================================================
-- BEAT POLYGONS WITHOUT A GEOMETRY EXTENSION
-- =============================================================================
--
-- 7.17 tags a call with its beat automatically. MariaDB does have spatial types
-- and `ST_Contains`, and this file deliberately does not use them: the point
-- test has to run in `service.lua` (which holds the logic and no natives, so
-- busted can test it), it has to run for a call raised by an export before that
-- call is written, and on a server whose operator has replaced the database
-- with something that answers to MySQL, spatial support is not a promise
-- FredPD can make on their behalf.
--
-- So a polygon is a JSON array of `[x, y]` pairs and the test is an ordinary
-- ray cast in Lua. The `min_x`/`min_y`/`max_x`/`max_y` columns are the bounding
-- box: comparing four doubles rejects almost every beat before the ray cast
-- runs, which is what keeps tagging off the 50 ms route budget (12.1) when an
-- agency has drawn thirty districts.
--
-- The bounding box is the one derived value in this file the database does not
-- compute, because deriving it needs `JSON_TABLE` and that is not allowed in a
-- generated column. It must therefore be written by the same statement that
-- writes the polygon, from one function in `service.lua` that busted tests, and
-- no route may accept one from input: the CHECK below catches an inverted box,
-- but a box that is merely *too small* is valid SQL and silently stops tagging
-- calls in part of a district, which looks like a quiet beat rather than a bug.
--
--
-- =============================================================================
-- WHAT HAPPENS WHEN AN OFFICER IS DELETED
-- =============================================================================
--
-- A roster row can be removed -- somebody leaves the department -- and the
-- question each table below had to answer is whether it is live state or
-- history.
--
--   * `fpd_units` is live state: the board. `ON DELETE CASCADE`, because a unit
--     row for an officer who is no longer on the roster is a ghost on the
--     board, and a ghost with a stale position is worse than an empty row.
--   * `fpd_call_units`, `fpd_call_log` and `fpd_alpr_reads` are history.
--     `ON DELETE SET NULL` on `officer_id`, and each of them also stores the
--     `discord_id` and the `callsign` **as recorded at the time**, which are
--     plain columns no foreign key touches. So "3A-12 was on this call and
--     cleared it Code 4" survives the officer being removed from the roster,
--     exactly as `fpd_firearm_events` keeps `from_party` (0005).
--   * `fpd_calls` itself stores authors as Discord ids (`created_by`,
--     `cleared_by`), never as a foreign key, for the same reason the audit log
--     does: the record of who did something must outlive their roster entry.
--
--
-- =============================================================================
-- MARIADB GOTCHAS: ERROR 1901, AND ITS COUSIN
-- =============================================================================
--
-- **Error 1901** (first met in 0002, `fpd_forensic_index`): a CHECK constraint
-- may not reference a column that a foreign key sets to NULL. Every
-- `ON DELETE SET NULL` in this file therefore points at a column no CHECK
-- mentions -- `fpd_calls.beat_id`, `fpd_call_units.officer_id`,
-- `fpd_call_log.officer_id`, `fpd_units.beat_id`, `fpd_broadcasts.call_id`,
-- `fpd_alpr_reads.officer_id`, `fpd_alpr_reads.hotlist_id` -- and every CHECK
-- here sits on a column no foreign key touches at all. Read that list against
-- the constraints before adding either kind.
--
-- **The same restriction for generated columns.** A foreign key whose action is
-- `SET NULL` or `CASCADE` may not sit on a base column of a stored generated
-- column. That is why `queue_priority` is generated from `status` and
-- `priority`, `active` from `left_at`, `lead_live` from `is_lead` and
-- `left_at`, and `live` from `cancelled_at` -- not one of those base columns is
-- written by a foreign key. The two rules are the same rule wearing different
-- error numbers: the database refuses to let a cascade produce a row it would
-- then have to recompute or reject.
--
-- **`IF NOT EXISTS` everywhere,** because CI applies every migration twice
-- against the same database and the second pass must be a no-op rather than
-- error 1050.
--
--
-- =============================================================================
-- THREE THINGS THIS FILE DELIBERATELY DOES *NOT* DO
-- =============================================================================
--
-- **No `current_call_id` on `fpd_units`.** The board wants "what is this unit
-- on", and a column holding it would be a copy of `fpd_call_units`, with a
-- window in which the two disagree -- the same objection 0005 raises to a
-- materialised hot-file table, and with the same failure mode: a dispatcher
-- looking at a board that says a unit is free while the call it is actually on
-- is still open. `idx_fpd_call_units_unit` makes the live lookup a key seek, so
-- the board is one join rather than one copy.
--
-- **No per-unit arrival timestamps on `fpd_call_units`.** A unit's own en-route
-- and on-scene moments are status changes, and every status change is already
-- a row in `fpd_call_log` with an author and a time. Two places to read "when
-- did 3A-12 arrive" is one place too many when the answer is quoted in court.
--
-- **No `agency_id` filter left to the reader.** Every table here carries
-- `agency_id` and every index starts with it. FredPD is multi-agency: a queue
-- query that forgets the agency does not return an empty list, it returns the
-- sheriff's calls to a city dispatcher, and it does so quietly.
--
-- **Naming note.** Spec 13.2 lists this area as `fpd_call_events`,
-- `fpd_unit_status_log`, `fpd_messages` and `fpd_bulletins`. The names below --
-- `fpd_call_log`, `fpd_broadcasts` -- are the ones M4 is being built against,
-- and they are fewer: a call event is a line in the call log, and a bulletin
-- with an expiry is a broadcast.
--
-- Two of the spec's tables are genuinely absent rather than renamed, and both
-- are worth knowing about before somebody looks for them:
--
--   * **`fpd_unit_status_log` (7.1) is not here.** `fpd_units.status_since`
--     gives the board its time-in-status and gives 7.16 its welfare-check
--     timer, and a status change made *on a call* is a line in that call's log
--     with an author and a time. What is not kept is the history of status
--     changes made off a call -- an activity report over a whole shift. That
--     is a personnel question (7.22, M6) and the table it needs is one a later
--     migration adds; nothing in M4 reads it, and a required table nobody
--     writes to is worse than an honest gap.
--   * **`fpd_premise_hazards` (7.6) is not here.** 7.6 is [S] and unbuilt. The
--     call card shows hazards when that table exists.


-- =============================================================================
-- BEATS AND DISTRICTS (spec 7.17)
-- =============================================================================

-- A beat is a polygon, a precedence and a label. Districts are the same table:
-- a district is a large polygon with a low precedence and a beat is a small one
-- inside it with a higher precedence, so the tagger takes the highest
-- precedence polygon that contains the point and one routine answers both.
--
-- `label_key` is a locale key, never a name (invariant 6), the same choice
-- `fpd_fleet` and `fpd_placements` made -- and for the same reason: a Swedish
-- dispatcher must not read "Downtown" because an English-speaking administrator
-- drew the polygon.
--
-- `polygon` is declared JSON, which on MariaDB is LONGTEXT carrying an
-- automatic `json_valid` constraint; the named CHECK below adds the part that
-- does not give: three vertices, because two points are a line and a line
-- contains nothing. The array is `[[x, y], [x, y], …]` in world coordinates,
-- implicitly closed (the last vertex joins the first). Z is deliberately absent
-- -- a beat is a map area, and an officer in a basement is in the beat above
-- them.
CREATE TABLE IF NOT EXISTS `fpd_beats` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `code`        VARCHAR(32)     NOT NULL COMMENT 'Short operational name: B12, ADAM, NORR',
    `label_key`   VARCHAR(128)    NOT NULL COMMENT 'Locale key, never a literal name (invariant 6)',
    `kind`        VARCHAR(16)     NOT NULL DEFAULT 'beat' COMMENT 'beat | district',

    `polygon`     JSON            NOT NULL COMMENT '[[x,y],…] world coordinates, implicitly closed',
    -- The bounding box of `polygon`, written by the service in the same
    -- statement. A cheap rejection before the ray cast (see the header).
    `min_x`       DOUBLE          NOT NULL,
    `min_y`       DOUBLE          NOT NULL,
    `max_x`       DOUBLE          NOT NULL,
    `max_y`       DOUBLE          NOT NULL,

    -- Highest precedence wins where polygons overlap. A plain integer rather
    -- than a parent link: nesting in a real district map is not a tree, two
    -- districts share a border, and an ordering answers the only question the
    -- tagger asks.
    `precedence`  SMALLINT        NOT NULL DEFAULT 0,
    `enabled`     TINYINT(1)      NOT NULL DEFAULT 1 COMMENT 'Off without deleting, so history keeps its beat',

    `created_by`  VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_by`  VARCHAR(32)     NULL,
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_beats_code` (`agency_id`, `code`),
    -- The tagger's load: every enabled polygon for one agency, ordered by
    -- precedence. It reads `ORDER BY precedence DESC` -- highest precedence is
    -- the most specific polygon, so the first one that contains the point is
    -- the answer -- and an index is read backwards as cheaply as forwards.
    KEY `idx_fpd_beats_active` (`agency_id`, `enabled`, `precedence`),
    CONSTRAINT `fk_fpd_beats_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- Safe from 1901: the only foreign key on this table is `agency_id`, which
    -- cascades rather than nulling, and no CHECK here mentions it.
    CONSTRAINT `ck_fpd_beats_kind` CHECK (`kind` IN ('beat', 'district')),
    CONSTRAINT `ck_fpd_beats_polygon` CHECK (
        JSON_VALID(`polygon`) AND JSON_LENGTH(`polygon`) >= 3),
    -- An inverted box matches nothing, so a beat with one would stop tagging
    -- calls and look like a beat nobody patrols.
    CONSTRAINT `ck_fpd_beats_bbox` CHECK (`min_x` <= `max_x` AND `min_y` <= `max_y`),
    CONSTRAINT `ck_fpd_beats_code_value` CHECK (CHAR_LENGTH(TRIM(`code`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- CALLS (spec 7.16)
-- =============================================================================

-- One row per call.
--
-- `call_number` is allocated from `fpd_counters` under a row lock, like every
-- other number in the suite (13.1, ADR-012), and is never accepted from input
-- (invariant 1) -- including from the `CreateCall` export in 11.2, whose caller
-- is an alarm script with no business naming police record numbers.
--
-- One thing to know before writing that allocation: Appendix D's call format is
-- `{YYMMDD}-{####}`, which is scoped to a *day*, and `fpd_counters.year` is
-- `SMALLINT UNSIGNED`. A raw `YYMMDD` key (260918) does not fit in it and is
-- rejected under strict mode. Either scope the sequence to the year and let the
-- day live only in the printed number, or encode the day in range -- `YY * 400
-- + day_of_year` fits for every year the column can hold. Decide it once in
-- `dispatch/service.lua`, where busted can see it; do not discover it at three
-- in the morning on the first call of a new day.
--
-- `type` and `disposition` are code values rendered through `cad.callType.<x>`
-- and `cad.disposition.<x>` (5.3, invariant 6), and carry no CHECK: the code
-- tables grow, migrations are append-only, and an agency adding a call type
-- must not need a schema change first. The allowlist lives with the module,
-- where an unknown code fails at the call site with its name in the message.
CREATE TABLE IF NOT EXISTS `fpd_calls` (
    `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`      VARCHAR(32)     NOT NULL,
    `call_number`    VARCHAR(32)     NOT NULL COMMENT '260917-0042. Allocated from fpd_counters',

    `type`           VARCHAR(32)     NOT NULL COMMENT 'Code; rendered from cad.callType.<type>',
    `priority`       TINYINT UNSIGNED NOT NULL DEFAULT 3 COMMENT 'P1 life-threatening … P4 report only',
    `status`         VARCHAR(16)     NOT NULL DEFAULT 'pending',

    -- Where. Both halves are nullable and the CHECKs below require at least one
    -- of them: a phone caller who can only give a street name produces a call
    -- with text and no coordinates, and a panic button produces the reverse.
    -- A call with neither is a call nobody can be sent to.
    `x`              DOUBLE          NULL,
    `y`              DOUBLE          NULL,
    `z`              DOUBLE          NULL,
    `location_text`  VARCHAR(191)    NULL COMMENT 'As given: a street, a premise, a cross street',
    `beat_id`        BIGINT UNSIGNED NULL COMMENT 'Tagged automatically from the position (7.17)',

    -- The caller as recorded at the time, which is not the same thing as a
    -- person record: a name given on the phone is often wrong and is evidence
    -- of what was said, not of who it was. The resolved person, when somebody
    -- resolves one, is a `caller` row in `fpd_call_links`.
    `caller_name`    VARCHAR(191)    NULL,
    `caller_phone`   VARCHAR(32)     NULL,

    -- How the call arrived (7.16 intake). `export` is the 11.2 `CreateCall`
    -- path, which has no session behind it -- an alarm script is not an
    -- officer -- which is why `created_by` below is nullable.
    `source`         VARCHAR(16)     NOT NULL DEFAULT 'dispatcher',
    `source_resource` VARCHAR(64)    NULL COMMENT 'Which resource called CreateCall, for the audit trail',

    -- The five timestamps 7.16 names. `received_at` is when the call came in;
    -- the other four are NULL until the call reaches that stage, and are
    -- stamped once and never moved (see the header).
    `received_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `dispatched_at`  DATETIME(3)     NULL COMMENT 'First unit assigned, self-assignment included',
    `en_route_at`     DATETIME(3)     NULL COMMENT 'First unit en route',
    `on_scene_at`    DATETIME(3)     NULL COMMENT 'First unit on scene',
    `cleared_at`     DATETIME(3)     NULL COMMENT 'Closed, whether cleared or cancelled',

    `disposition`    VARCHAR(32)     NULL COMMENT 'Code; rendered from cad.disposition.<x>',
    `cleared_by`     VARCHAR(32)     NULL COMMENT 'Discord id',

    -- The emergency button (7.16): a P1 call at the officer's position that
    -- "cannot be cleared without supervisor acknowledgement". The
    -- acknowledgement is two columns and a CHECK rather than a habit, because
    -- the habit is broken by the one dispatcher who clears the board at the end
    -- of a shift -- and an unacknowledged panic call is precisely the one that
    -- must still be there in the morning.
    `acknowledged_by` VARCHAR(32)    NULL COMMENT 'Discord id of the supervisor',
    `acknowledged_at` DATETIME(3)    NULL,

    `classification` VARCHAR(16)     NOT NULL DEFAULT 'internal',
    `version`        INT UNSIGNED    NOT NULL DEFAULT 1 COMMENT 'Optimistic lock (13.1) and the delta version (3.6)',
    `created_by`     VARCHAR(32)     NULL COMMENT 'Discord id; NULL for a call raised by an export',
    `created_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_by`     VARCHAR(32)     NULL,
    `updated_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    -- The pending queue, in one column. See the header for why this is not an
    -- index over `status`. Base columns `status` and `priority` carry no
    -- foreign key, which is what makes a stored generated column legal here.
    `queue_priority` TINYINT UNSIGNED
        AS (CASE WHEN `status` IN ('cleared', 'cancelled') THEN NULL ELSE `priority` END) STORED,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_calls_number` (`agency_id`, `call_number`),
    -- The target of the composite foreign keys on the three child tables, so
    -- the database itself guarantees a call's units, log and links cannot drift
    -- into another agency (the shape `fpd_persons` uses in 0005).
    UNIQUE KEY `uq_fpd_calls_id_agency` (`id`, `agency_id`),
    -- The pending queue and the map: open calls, P1 first, oldest first.
    KEY `idx_fpd_calls_queue` (`agency_id`, `queue_priority`, `received_at`),
    -- One status at a time: the closed-call list, and the retention sweep.
    KEY `idx_fpd_calls_status` (`agency_id`, `status`, `received_at`),
    -- Everything today, in order, whatever the status -- the call history page
    -- and the response-time report, neither of which can use the queue index
    -- because both span closed calls.
    KEY `idx_fpd_calls_received` (`agency_id`, `received_at`),
    -- Beat first, not agency first: a beat belongs to exactly one agency, so
    -- this answers "the calls in this district" as well as the agency-first
    -- shape would -- and InnoDB requires an index whose leftmost column is the
    -- foreign key's, or it silently creates an unnamed one of its own. Every
    -- foreign key in this file is covered by an index declared here, the way
    -- `idx_fpd_vehicles_owner` covers its own in 0005.
    KEY `idx_fpd_calls_beat` (`beat_id`, `received_at`),

    CONSTRAINT `fk_fpd_calls_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- Single-column and `SET NULL`: a call outlives the beat map being redrawn,
    -- and a composite key would have to null `agency_id` too, which MariaDB
    -- refuses over a NOT NULL column (0005 met the same wall on owner links).
    -- No CHECK below mentions `beat_id` -- that would be error 1901.
    CONSTRAINT `fk_fpd_calls_beat` FOREIGN KEY (`beat_id`)
        REFERENCES `fpd_beats` (`id`) ON DELETE SET NULL,

    CONSTRAINT `ck_fpd_calls_priority` CHECK (`priority` BETWEEN 1 AND 4),
    CONSTRAINT `ck_fpd_calls_status` CHECK (`status` IN
        ('pending', 'dispatched', 'en_route', 'on_scene', 'cleared', 'cancelled')),
    CONSTRAINT `ck_fpd_calls_source` CHECK (`source` IN
        ('dispatcher', 'phone', 'export', 'panic', 'alpr')),
    CONSTRAINT `ck_fpd_calls_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),

    -- A position is all three coordinates or none of them. Two thirds of a
    -- position puts a marker on the map at Z = 0, under the map.
    CONSTRAINT `ck_fpd_calls_position` CHECK (
        (`x` IS NULL AND `y` IS NULL AND `z` IS NULL)
        OR (`x` IS NOT NULL AND `y` IS NOT NULL AND `z` IS NOT NULL)),
    -- Somewhere to go: coordinates, or words, or both.
    CONSTRAINT `ck_fpd_calls_where` CHECK (
        `x` IS NOT NULL OR `location_text` IS NOT NULL),

    -- The status and the timestamps agree, one rung at a time.
    --
    -- Deliberately per-status rather than a chain (`on_scene` implies
    -- `dispatched_at`, and so on). The module is expected to stamp
    -- `dispatched_at` on the first assignment however it happened -- a
    -- dispatcher's or the officer's own -- so in practice the chain holds;
    -- but a CHECK that enforces it turns any future flow that skips a rung into
    -- a failed write at the moment an officer presses a key over a body, and
    -- the rung most likely to be skipped is the one nobody thought of. Each
    -- constraint here forbids exactly the state it names and nothing else.
    CONSTRAINT `ck_fpd_calls_dispatched` CHECK (
        `status` <> 'dispatched' OR `dispatched_at` IS NOT NULL),
    CONSTRAINT `ck_fpd_calls_en_route` CHECK (
        `status` <> 'en_route' OR `en_route_at` IS NOT NULL),
    CONSTRAINT `ck_fpd_calls_on_scene` CHECK (
        `status` <> 'on_scene' OR `on_scene_at` IS NOT NULL),
    -- Both terminal statuses close the call, so both stamp `cleared_at`;
    -- only `cleared` carries a disposition, because "cancelled" is the
    -- disposition of a cancelled call and 7.16 asks for a code on the other.
    CONSTRAINT `ck_fpd_calls_closed` CHECK (
        `status` NOT IN ('cleared', 'cancelled') OR `cleared_at` IS NOT NULL),
    CONSTRAINT `ck_fpd_calls_disposition` CHECK (
        `status` <> 'cleared' OR `disposition` IS NOT NULL),
    -- Nothing may be stamped before the call existed. Comparisons against NULL
    -- are unknown rather than false, so these hold for a call that has not
    -- reached the stage yet.
    CONSTRAINT `ck_fpd_calls_order` CHECK (
        (`dispatched_at` IS NULL OR `dispatched_at` >= `received_at`)
        AND (`en_route_at` IS NULL OR `en_route_at` >= `received_at`)
        AND (`on_scene_at` IS NULL OR `on_scene_at` >= `received_at`)
        AND (`cleared_at` IS NULL OR `cleared_at` >= `received_at`)),
    -- 7.16: an emergency call cannot be cleared without supervisor
    -- acknowledgement. Cancelling one is closed off for the same reason --
    -- otherwise the way to clear an unacknowledged panic call is to cancel it.
    CONSTRAINT `ck_fpd_calls_panic_ack` CHECK (
        `source` <> 'panic'
        OR `status` NOT IN ('cleared', 'cancelled')
        OR `acknowledged_at` IS NOT NULL)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- Which units are on a call, who has the lead, and when they joined and left
-- (7.16).
--
-- A row per assignment rather than per unit, because a unit can be assigned,
-- cleared to something more urgent, and assigned back -- and the response-time
-- question is about the assignment, not about the unit. `left_at` closes a row;
-- nothing is deleted.
--
-- The two generated columns are the `fpd_record_seals` trick from 0005 applied
-- twice over. `active` is 1 while the assignment is open and NULL once it is
-- closed, so the unique key below means "a unit is on a call once at a time"
-- while any number of closed assignments coexist (NULLs are distinct in a
-- MariaDB unique index). `lead_live` does the same for the lead unit: at most
-- one live lead per call, enforced by the database rather than by a
-- check-then-insert in Lua that two dispatchers can interleave. A call with two
-- lead units is a call where nobody is in charge and both think the other is.
--
-- `discord_id` and `callsign` are recorded here as they were at the time, so a
-- deleted roster row (`officer_id` nulled) still leaves a readable unit list --
-- and so the live-assignment unique key keeps working, since it is keyed on
-- `discord_id` rather than on the nullable `officer_id`.
CREATE TABLE IF NOT EXISTS `fpd_call_units` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `call_id`     BIGINT UNSIGNED NOT NULL,

    `officer_id`  BIGINT UNSIGNED NULL COMMENT 'Nulled if the roster row goes; see discord_id',
    `discord_id`  VARCHAR(32)     NOT NULL COMMENT 'From the session, never from input',
    `callsign`    VARCHAR(32)     NULL COMMENT 'As it was at assignment',

    `is_lead`     TINYINT(1)      NOT NULL DEFAULT 0,
    `joined_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `left_at`     DATETIME(3)     NULL COMMENT 'NULL while the unit is on the call',
    `assigned_by` VARCHAR(32)     NULL COMMENT 'Discord id; equal to discord_id on a self-assign',

    `active`      TINYINT UNSIGNED AS (CASE WHEN `left_at` IS NULL THEN 1 ELSE NULL END) STORED,
    `lead_live`   TINYINT UNSIGNED
        AS (CASE WHEN `left_at` IS NULL AND `is_lead` = 1 THEN 1 ELSE NULL END) STORED,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_call_units_live` (`call_id`, `discord_id`, `active`),
    UNIQUE KEY `uq_fpd_call_units_lead` (`call_id`, `lead_live`),
    -- "Who is on this call", which is the card, in join order. `agency_id`
    -- sits in the middle so this index also covers the composite foreign key
    -- below (leftmost `call_id`, `agency_id`); every read carries the agency
    -- anyway, so the ordering is unaffected.
    KEY `idx_fpd_call_units_call` (`call_id`, `agency_id`, `joined_at`),
    -- "What is this unit on", which is the board -- and the reason `fpd_units`
    -- needs no `current_call_id` copy (see the header).
    KEY `idx_fpd_call_units_unit` (`agency_id`, `discord_id`, `active`),
    KEY `idx_fpd_call_units_officer` (`officer_id`),

    CONSTRAINT `fk_fpd_call_units_call` FOREIGN KEY (`call_id`, `agency_id`)
        REFERENCES `fpd_calls` (`id`, `agency_id`) ON DELETE CASCADE,
    -- Single-column `SET NULL` for the reason given on `fpd_calls.beat_id`, and
    -- `officer_id` is mentioned by no CHECK here (error 1901) and by no
    -- generated column (its cousin, see the header).
    CONSTRAINT `fk_fpd_call_units_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_call_units_left` CHECK (
        `left_at` IS NULL OR `left_at` >= `joined_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- The narrative log (7.16): every note and every status change, append-only,
-- with an author.
--
-- Nothing in the application updates or deletes a row here. It is the record of
-- what was known and when, which is the half of a call that is read back in an
-- inquiry, and a narrative that can be edited afterwards is worth nothing in
-- one.
--
-- **Invariant 6 is enforced by the schema, not by discipline.** A log has two
-- kinds of line: what a person typed, which is content, and what the system
-- recorded, which is user-facing text. `body` holds the first. `message_key`
-- plus `message_args` hold the second -- `cad.log.dispatched` with
-- `{"callsign": "3A-12"}` -- and the NUI renders it in the reader's language.
-- The CHECK makes the wrong one impossible to store: a generated line with an
-- English sentence in `body` would be a Swedish dispatcher reading English, and
-- the i18n checker cannot see a sentence that reaches the database.
--
-- The author is nullable on purpose. A call raised by the `CreateCall` export
-- (11.2) has no officer behind it, and its first log line is written before any
-- session exists; a NOT NULL author would mean an alarm script could not open a
-- call at all.
CREATE TABLE IF NOT EXISTS `fpd_call_log` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`    VARCHAR(32)     NOT NULL,
    `call_id`      BIGINT UNSIGNED NOT NULL,

    `entry_type`   VARCHAR(16)     NOT NULL
                                   COMMENT 'The event that happened; the list is ck_fpd_call_log_type below',
    `body`         VARCHAR(2048)   NULL COMMENT 'What a person typed. Content, not UI text',
    `message_key`  VARCHAR(128)    NULL COMMENT 'Locale key for a generated line (invariant 6)',
    `message_args` JSON            NULL COMMENT 'Placeholder values for message_key',

    `officer_id`   BIGINT UNSIGNED NULL COMMENT 'Nulled if the roster row goes; see discord_id',
    `discord_id`   VARCHAR(32)     NULL COMMENT 'From the session; NULL for a system line',
    `callsign`     VARCHAR(32)     NULL COMMENT 'As it was when the line was written',
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    -- The call card, in order. Keyset pagination on `id` for a long call
    -- (12.2), and `agency_id` in the middle so this covers the composite
    -- foreign key too.
    KEY `idx_fpd_call_log_call` (`call_id`, `agency_id`, `id`),
    -- "Everything this officer wrote", the other half of a misuse enquiry.
    KEY `idx_fpd_call_log_author` (`agency_id`, `discord_id`, `created_at`),

    CONSTRAINT `fk_fpd_call_log_call` FOREIGN KEY (`call_id`, `agency_id`)
        REFERENCES `fpd_calls` (`id`, `agency_id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_call_log_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE SET NULL,
    -- Safe from 1901: neither foreign key writes `entry_type`, `body` or
    -- `message_key`.
    CONSTRAINT `ck_fpd_call_log_type` CHECK (`entry_type` IN
        ('created', 'note', 'dispatched', 'unit_joined', 'unit_left',
         'lead_changed', 'unit_status', 'call_status', 'linked', 'unlinked',
         'cleared')),
    CONSTRAINT `ck_fpd_call_log_content` CHECK (
        (`entry_type` = 'note' AND `body` IS NOT NULL)
        OR (`entry_type` <> 'note' AND `message_key` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- Persons and vehicles linked to a call (7.16).
--
-- **Polymorphic, with no foreign key to the record,** which is the same shape
-- `fpd_record_compartments` (0005) and `fpd_hotfile_confirmations` (0006) use,
-- and it is chosen here for a reason those two do not have: the alternative --
-- a nullable `person_id` and a nullable `vehicle_id`, each with `ON DELETE SET
-- NULL` -- cannot be constrained. A CHECK that exactly one of them is populated
-- is error 1901 twice over, so the one rule that matters ("a link points at
-- something") would be unenforceable, and the unique key that stops a
-- dispatcher linking the same suspect four times would be keyed on nullable
-- columns and therefore not unique at all.
--
-- The cost is that an expunged person leaves a link row pointing at nothing.
-- That is the safe direction -- an orphan link grants nobody anything, and the
-- retention sweep takes it -- and `label` keeps the plate or the name as it was
-- read out over the radio, which is what the call is read back for anyway.
--
-- The repo must therefore check that the target belongs to the session's agency
-- before writing, because without a foreign key the database cannot -- and a
-- link is one of the few places a client supplies a record id at all.
CREATE TABLE IF NOT EXISTS `fpd_call_links` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `call_id`     BIGINT UNSIGNED NOT NULL,

    `target_type` VARCHAR(16)     NOT NULL COMMENT 'person | vehicle',
    `target_id`   BIGINT UNSIGNED NOT NULL COMMENT 'fpd_persons.id or fpd_vehicles.id',
    `role`        VARCHAR(24)     NOT NULL DEFAULT 'involved',
    `label`       VARCHAR(191)    NULL COMMENT 'Name or plate as recorded, so the row survives the record',
    `detail`      VARCHAR(512)    NULL,

    `created_by`  VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    -- One link per record per call. Changing the role updates the row rather
    -- than stacking a second one nobody would think to remove -- the same
    -- upsert `fpd_record_grants` relies on in 0005.
    UNIQUE KEY `uq_fpd_call_links_target` (`call_id`, `target_type`, `target_id`),
    -- "Every call this person has been on", which is the record page and the
    -- reason the link is worth storing at all.
    KEY `idx_fpd_call_links_record` (`agency_id`, `target_type`, `target_id`, `created_at`),
    -- Covers the composite foreign key below; the unique key above starts with
    -- `call_id` but not with `call_id, agency_id`, so without this InnoDB
    -- creates an unnamed index of its own.
    KEY `idx_fpd_call_links_call` (`call_id`, `agency_id`),

    CONSTRAINT `fk_fpd_call_links_call` FOREIGN KEY (`call_id`, `agency_id`)
        REFERENCES `fpd_calls` (`id`, `agency_id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_call_links_target` CHECK (`target_type` IN ('person', 'vehicle')),
    CONSTRAINT `ck_fpd_call_links_role` CHECK (`role` IN
        ('caller', 'victim', 'suspect', 'witness', 'involved'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- THE UNIT BOARD AND AVL (spec 7.1, 7.16, 7.17)
-- =============================================================================

-- One row per officer signed on, keyed by `officer_id`.
--
-- **Per officer, not per session.** A session is a connection: it ends when the
-- server restarts, when the player's game crashes, and every time they change
-- character. A unit is a person on duty, and it has to survive all three --
-- an officer who reconnects mid-call must come back as the same unit, on the
-- same call, with the same time-in-status, or the board reports them as having
-- gone available at the moment their game crashed.
--
-- The cost of persisting it is ghosts: rows left behind by a restart. The
-- module must clear those at boot by setting every unit of the agency
-- `off_duty`, because after a restart there is no session to contradict the
-- row. That sweep writes a status nobody asked for, which is the right
-- direction to be wrong in: a board that has forgotten a real unit is corrected
-- by that unit pressing one key, and a board still showing a unit who left two
-- hours ago sends somebody to a call nobody is going to.
--
-- **Callsign is deliberately not unique.** A two-officer car signs on under one
-- callsign (7.1 partners), so uniqueness would forbid partners; the board
-- groups by callsign instead.
--
-- The position columns are the AVL (7.17) and no client writes them. See the
-- header.
CREATE TABLE IF NOT EXISTS `fpd_units` (
    `officer_id`    BIGINT UNSIGNED NOT NULL,
    `agency_id`     VARCHAR(32)     NOT NULL,
    `discord_id`    VARCHAR(32)     NOT NULL COMMENT 'From the session, never from input',

    `callsign`      VARCHAR(32)     NOT NULL,
    `status`        VARCHAR(16)     NOT NULL DEFAULT 'available',
    -- When the status last changed -- the board's "time in status" column, and
    -- what the welfare-check timer reads (7.16: a unit on scene too long).
    -- The module stamps this on a status change and on nothing else. It is
    -- deliberately not `ON UPDATE CURRENT_TIMESTAMP(3)`: the AVL sweep writes
    -- this row every second or two, and an automatic stamp would reset the
    -- timer on every sweep -- so the welfare check would never fire, and it
    -- would never fire for the unit that has stopped moving.
    `status_since`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    `beat_id`       BIGINT UNSIGNED NULL COMMENT 'Assignment (7.1), not where they are',
    `division`      VARCHAR(32)     NULL,
    `vehicle_plate` VARCHAR(16)     NULL COMMENT 'Auto-detected agency vehicle (7.1)',
    `vehicle_model` VARCHAR(64)     NULL,

    -- Last known position, read server-side off the ped (invariant 1, D1).
    -- NULL until the first sweep sees them, and left as it was when they
    -- disconnect: "last known" is the honest name for it.
    `x`             DOUBLE          NULL,
    `y`             DOUBLE          NULL,
    `z`             DOUBLE          NULL,
    `heading`       FLOAT           NULL COMMENT 'Which way the marker points',
    `position_at`   DATETIME(3)     NULL COMMENT 'When the position was read; stale is not the same as unknown',

    `signed_on_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`officer_id`),
    -- The board: every unit for the agency, grouped by status, oldest in status
    -- first -- which is also the welfare-check query (status, status_since).
    KEY `idx_fpd_units_board` (`agency_id`, `status`, `status_since`),
    KEY `idx_fpd_units_callsign` (`agency_id`, `callsign`),
    -- Sign-on, and the AVL sweep resolving a connected player to their unit.
    KEY `idx_fpd_units_discord` (`discord_id`),
    -- Beat first, so it covers the foreign key as well as "who is working this
    -- beat" (a beat belongs to one agency, so nothing is lost).
    KEY `idx_fpd_units_beat` (`beat_id`),

    -- CASCADE, not SET NULL: this is live state, and a unit row for an officer
    -- who is no longer on the roster is a ghost on the board (see the header).
    CONSTRAINT `fk_fpd_units_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_units_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_units_beat` FOREIGN KEY (`beat_id`)
        REFERENCES `fpd_beats` (`id`) ON DELETE SET NULL,
    -- Appendix E, plus `off_duty` for a row kept across a sign-off. Safe from
    -- 1901: no foreign key writes `status`, `callsign` or the coordinates.
    CONSTRAINT `ck_fpd_units_status` CHECK (`status` IN
        ('off_duty', 'available', 'en_route', 'on_scene', 'busy',
         'transporting', 'at_station', 'out_of_service', 'emergency')),
    CONSTRAINT `ck_fpd_units_callsign` CHECK (CHAR_LENGTH(TRIM(`callsign`)) > 0),
    -- All three coordinates or none: a half-read position puts a unit under the
    -- map, and the recommendation routine would then offer it as the closest.
    CONSTRAINT `ck_fpd_units_position` CHECK (
        (`x` IS NULL AND `y` IS NULL AND `z` IS NULL)
        OR (`x` IS NOT NULL AND `y` IS NOT NULL AND `z` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- BROADCASTS (spec 7.16, 7.26)
-- =============================================================================

-- BOLOs and all-units messages, with an expiry.
--
-- `title` and `body` are content an officer wrote, not UI text, so they are
-- stored as typed -- the same distinction `fpd_call_log` draws between `body`
-- and `message_key`.
--
-- An expired broadcast is not deleted and a cancelled one is stamped, never
-- removed: "what was out on the air at the time" is a question asked after an
-- arrest, and the answer has to survive the shift it was asked about.
--
-- Not to be confused with the enforcement BOLO of spec 7.13 -- a record with a
-- subject, a case and a lifecycle, which is M2 and which no migration has
-- built yet; what exists today is the vehicle flag `fpd_vehicle_flags.kind =
-- 'bolo'` (0005). A broadcast is the *message*:
-- it may carry a BOLO, a road closure or a briefing note, and it expires on its
-- own without anything happening to the record behind it.
CREATE TABLE IF NOT EXISTS `fpd_broadcasts` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`    VARCHAR(32)     NOT NULL,

    `kind`         VARCHAR(24)     NOT NULL DEFAULT 'all_units'
                                   COMMENT 'Widest member is attempt_to_locate, 17 chars',
    `priority`     TINYINT UNSIGNED NOT NULL DEFAULT 3 COMMENT 'Same 1-4 scale as a call',
    `title`        VARCHAR(191)    NOT NULL,
    `body`         VARCHAR(2048)   NOT NULL,
    -- The plate a lookout is for. Content, like `title` and `body`: it is
    -- what a unit matches an ALPR read against by eye, and it is not a
    -- hotlist entry -- a banner is `fpd_hotlist`, under its own permission
    -- (7.18). No index: the board is read whole through the live index, and
    -- one here would cost every insert to serve a lookup nothing performs.
    `plate`        VARCHAR(16)     NULL COMMENT 'Upper-cased and trimmed on write',
    `call_id`      BIGINT UNSIGNED NULL COMMENT 'The call it came out of, when there was one',

    `expires_at`   DATETIME(3)     NULL COMMENT 'NULL runs until it is cancelled',
    `cancelled_at` DATETIME(3)     NULL,
    `cancelled_by` VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_by`   VARCHAR(32)     NULL COMMENT 'Discord id; NULL for a system broadcast',
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    -- What is out right now: live, unexpired, newest first. The same live-flag
    -- index shape `fpd_vehicle_flags` uses in 0005 -- two equalities and a
    -- range, because expiry is a time and cannot be a generated flag.
    KEY `idx_fpd_broadcasts_live` (`agency_id`, `cancelled_at`, `expires_at`),
    KEY `idx_fpd_broadcasts_history` (`agency_id`, `created_at`),
    KEY `idx_fpd_broadcasts_call` (`call_id`),

    CONSTRAINT `fk_fpd_broadcasts_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- `SET NULL`, so the retention sweep over old calls cannot take a standing
    -- BOLO off the air with them. No CHECK below mentions `call_id` (1901).
    CONSTRAINT `fk_fpd_broadcasts_call` FOREIGN KEY (`call_id`)
        REFERENCES `fpd_calls` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_broadcasts_kind` CHECK (`kind` IN
        ('bolo', 'all_units', 'attempt_to_locate', 'information')),
    CONSTRAINT `ck_fpd_broadcasts_priority` CHECK (`priority` BETWEEN 1 AND 4),
    CONSTRAINT `ck_fpd_broadcasts_body` CHECK (CHAR_LENGTH(TRIM(`body`)) > 0),
    CONSTRAINT `ck_fpd_broadcasts_plate` CHECK (
        `plate` IS NULL OR CHAR_LENGTH(TRIM(`plate`)) > 0),
    -- An expiry before the broadcast was written is a message that was never on
    -- the air, which is a typed date, not an intention.
    CONSTRAINT `ck_fpd_broadcasts_expiry` CHECK (
        `expires_at` IS NULL OR `expires_at` > `created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- ALPR (spec 7.18)
-- =============================================================================

-- The plate hotlist: plates worth a banner, and why.
--
-- **This is not a cache of the hot files, and nothing may sync one into it.**
-- 0005 is explicit that a hit is *derived* at query time from the record that
-- is the truth for it -- `fpd_vehicle_flags` for a stolen car, a warrant for a
-- wanted person -- because a copy has a window in which it disagrees with the
-- record, and the window is discovered by the officer the stale hit points a
-- gun at. That reasoning has not changed, and an ALPR read runs the same
-- derived check every query runs.
--
-- This table is the layer underneath it: plate-level entries that no record can
-- produce. A plate seen leaving a scene with no vehicle record behind it; a
-- plate an investigator wants flagged for a week without a flag on the
-- registration; a surveillance target whose hit must not raise a banner at all.
-- Every row here is its own truth, written by a person who can be named, with
-- an expiry.
--
-- `silent` is the surveillance case (7.18, and section 9): the read is logged
-- and the hit is recorded, and the unit is told nothing. A banner would tell a
-- corrupt officer they are being watched, and the officer is sometimes the
-- subject.
CREATE TABLE IF NOT EXISTS `fpd_hotlist` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`    VARCHAR(32)     NOT NULL,

    `plate`        VARCHAR(16)     NOT NULL COMMENT 'Upper-cased and trimmed on write',
    `reason`       VARCHAR(16)     NOT NULL COMMENT 'Why it is on the list',
    `detail`       VARCHAR(512)    NULL,
    `case_number`  VARCHAR(32)     NULL,
    `silent`       TINYINT(1)      NOT NULL DEFAULT 0 COMMENT 'Log the hit, show the unit nothing',

    `expires_at`   DATETIME(3)     NULL COMMENT 'NULL stands until it is cancelled',
    `cancelled_at` DATETIME(3)     NULL,
    `cancelled_by` VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_by`   VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    `live`         TINYINT UNSIGNED AS (CASE WHEN `cancelled_at` IS NULL THEN 1 ELSE NULL END) STORED,

    PRIMARY KEY (`id`),
    -- One live entry per plate per reason. Adding a plate that is already
    -- listed for the same reason extends the existing row through
    -- `ON DUPLICATE KEY UPDATE` -- including re-arming one whose `expires_at`
    -- has passed -- rather than stacking a second row that raises two banners
    -- and that nobody would think to cancel twice. Cancelled rows drop out of
    -- the key, because NULLs are distinct in a MariaDB unique index.
    UNIQUE KEY `uq_fpd_hotlist_live` (`agency_id`, `plate`, `reason`, `live`),
    -- The check every read makes: this agency, this plate, still live, not
    -- expired. The unique key's `(agency_id, plate)` prefix would find the
    -- rows; this one also carries `live` and the expiry, so the check discards
    -- nothing after reading and never touches the table for a plate that is
    -- not listed -- which is almost every plate a patrol car drives past.
    KEY `idx_fpd_hotlist_check` (`agency_id`, `plate`, `live`, `expires_at`),
    KEY `idx_fpd_hotlist_manage` (`agency_id`, `cancelled_at`, `created_at`),

    CONSTRAINT `fk_fpd_hotlist_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- Safe from 1901 and from its generated-column cousin: the only foreign key
    -- here is `agency_id`, which cascades, and `live` is generated from
    -- `cancelled_at`, which no foreign key writes.
    CONSTRAINT `ck_fpd_hotlist_reason` CHECK (`reason` IN
        ('stolen_vehicle', 'wanted_person', 'warrant', 'bolo',
         'investigation', 'other')),
    CONSTRAINT `ck_fpd_hotlist_plate` CHECK (CHAR_LENGTH(TRIM(`plate`)) > 0),
    CONSTRAINT `ck_fpd_hotlist_expiry` CHECK (
        `expires_at` IS NULL OR `expires_at` > `created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- Plate reads: time, place and unit (7.18).
--
-- The highest-volume table in the suite by an order of magnitude -- one row per
-- plate a patrol car drives past -- so it is deliberately narrow: no
-- `classification`, no `version`, no `updated_at`, and no foreign key to the
-- vehicle register. Resolving a plate to a registration is done at read time
-- against `fpd_vehicles`; storing the resolved id would add a second index to
-- maintain on every insert and would be wrong the moment the plate changes
-- hands, which `fpd_vehicle_plates` (0005) exists to record.
--
-- Retention is 30 days by default (7.18, 13.3) and the sweep deletes by
-- `(agency_id, read_at)`, which `idx_fpd_alpr_reads_time` serves. This is the
-- one table in FredPD whose rows are meant to be deleted on a schedule: a
-- permanent record of every car every patrol has driven past is a movement
-- database, and 11.4 is why it does not become one.
--
-- `hit` and `hotlist_id` record what the read matched *at the time*, which is
-- not the same as what the hotlist says now, and that is the point: "was this
-- car flagged when the camera saw it" is the question a stop is justified by.
CREATE TABLE IF NOT EXISTS `fpd_alpr_reads` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `plate`       VARCHAR(16)     NOT NULL COMMENT 'Upper-cased and trimmed on write',
    `read_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `x`           DOUBLE          NOT NULL COMMENT 'Where the read happened, from the server (invariant 1)',
    `y`           DOUBLE          NOT NULL,
    `z`           DOUBLE          NOT NULL,

    `officer_id`  BIGINT UNSIGNED NULL COMMENT 'Nulled if the roster row goes; see discord_id',
    `discord_id`  VARCHAR(32)     NULL COMMENT 'NULL for a fixed camera with no unit behind it',
    `callsign`    VARCHAR(32)     NULL COMMENT 'As it was at the time of the read',
    `camera`      VARCHAR(16)     NULL COMMENT 'front | rear | fixed',

    `hit`         TINYINT(1)      NOT NULL DEFAULT 0 COMMENT 'Matched the hotlist when it was read',
    `hotlist_id`  BIGINT UNSIGNED NULL COMMENT 'Which entry matched, while that entry exists',

    PRIMARY KEY (`id`),
    -- "Where has this plate been", which is the whole reason to keep reads.
    KEY `idx_fpd_alpr_reads_plate` (`agency_id`, `plate`, `read_at`),
    -- The recent-reads list, and the retention sweep (13.3).
    KEY `idx_fpd_alpr_reads_time` (`agency_id`, `read_at`),
    -- Hits only, which is the review screen and a far smaller set.
    KEY `idx_fpd_alpr_reads_hit` (`agency_id`, `hit`, `read_at`),
    -- Both of these cover a foreign key. `hotlist_id` also answers "every read
    -- this hotlist entry matched", which is how an entry is reviewed before it
    -- is extended.
    KEY `idx_fpd_alpr_reads_officer` (`officer_id`),
    KEY `idx_fpd_alpr_reads_hotlist` (`hotlist_id`, `read_at`),

    CONSTRAINT `fk_fpd_alpr_reads_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_alpr_reads_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE SET NULL,
    -- The read outlives the hotlist entry that matched it -- cancelling a
    -- hotlist entry must not erase the evidence that a stop was justified when
    -- it was made. No CHECK mentions `hotlist_id` or `officer_id` (1901).
    CONSTRAINT `fk_fpd_alpr_reads_hotlist` FOREIGN KEY (`hotlist_id`)
        REFERENCES `fpd_hotlist` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_alpr_reads_plate` CHECK (CHAR_LENGTH(TRIM(`plate`)) > 0),
    CONSTRAINT `ck_fpd_alpr_reads_camera` CHECK (
        `camera` IS NULL OR `camera` IN ('front', 'rear', 'fixed'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The counter a call number is allocated from (Appendix D, ADR-012)
-- -----------------------------------------------------------------------------

-- `fpd_counters.year` is the sequence's SCOPE, not a year. 0005 declared it
-- SMALLINT UNSIGNED because every sequence then in existence was year-scoped or
-- unscoped. A call number restarts daily -- Appendix D gives `{YYMMDD}-{####}`
-- -- so its scope value is the day key 260918, which does not fit in 65535 and
-- is rejected outright under strict mode. The first call of the day would fail
-- to allocate a number, which is the first thing a dispatcher does.
--
-- MODIFY rather than a new column: the meaning is unchanged for every existing
-- row (0 unscoped, YYYY year-scoped) and only the range grows. Idempotent, so
-- CI's second pass over this file is a no-op. 0005 has shipped and is not
-- edited (invariant 8).
ALTER TABLE `fpd_counters`
    MODIFY COLUMN `year` MEDIUMINT UNSIGNED NOT NULL DEFAULT 0
    COMMENT 'Scope key: 0 = never restarts, YYYY = year-scoped, YYMMDD = day-scoped (calls)';
