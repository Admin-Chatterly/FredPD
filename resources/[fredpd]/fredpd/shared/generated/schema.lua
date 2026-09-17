--- GENERATED FILE -- DO NOT EDIT.
---
--- Written by `pnpm schema:gen` from packages/schema/src.
--- Change the TypeScript definitions and regenerate; CI fails on a stale copy.

FredPD = FredPD or {}

--- Route error codes (spec 3.5).
FredPD.ErrorCode = {
    NO_SESSION = 'no_session',
    FORBIDDEN = 'forbidden',
    CONTEXT = 'context',
    RATE_LIMITED = 'rate_limited',
    INVALID = 'invalid',
    NOT_FOUND = 'not_found',
    CONFLICT = 'conflict',
    RESTRICTED = 'restricted',
    STALE_PERMISSIONS = 'stale_permissions',
    INTERNAL = 'internal',
}

--- Where a session opened FredPD from (spec 1.4).
FredPD.AccessPoint = {
    MDC = 'mdc',
    TABLET = 'tablet',
    STATION = 'station',
    PROPERTY = 'property',
    LAB = 'lab',
    BOOKING = 'booking',
    DISPATCH = 'dispatch',
    COURTHOUSE = 'courthouse',
    PORTAL = 'portal',
}

--- Unit status (spec 7.1).
FredPD.UnitStatus = {
    AVAILABLE = 'available',
    EN_ROUTE = 'en_route',
    ON_SCENE = 'on_scene',
    BUSY = 'busy',
    OUT_OF_SERVICE = 'out_of_service',
    PANIC = 'panic',
}

--- What a world placement opens (spec 3.10).
FredPD.PlacementKind = {
    STATION_TERMINAL = 'station_terminal',
    PROPERTY_TERMINAL = 'property_terminal',
    LAB_TERMINAL = 'lab_terminal',
    BOOKING_TERMINAL = 'booking_terminal',
    DISPATCH_CONSOLE = 'dispatch_console',
    COURTHOUSE_TERMINAL = 'courthouse_terminal',
    MOTORPOOL = 'motorpool',
    EVIDENCE_BENCH = 'evidence_bench',
}

--- How a placement is reached in the world (spec 3.10).
FredPD.PlacementInteraction = {
    PROP = 'prop',
    PED = 'ped',
    ZONE = 'zone',
}

--- Route input schemas (spec 3.5). The route layer validates against these and
--- drops any key not listed, so a handler never sees a field it did not ask for.
FredPD.Schema = {
    PlacementList = {
        agencyId = { type = 'string', required = false, max = 32 },
    },

    PlacementCreate = {
        kind = { type = 'enum', required = true, values = { 'station_terminal', 'property_terminal', 'lab_terminal', 'booking_terminal', 'dispatch_console', 'courthouse_terminal', 'motorpool', 'evidence_bench' } },
        interaction = { type = 'enum', required = true, values = { 'prop', 'ped', 'zone' } },
        agencyId = { type = 'string', required = false, max = 32 },
        model = { type = 'string', required = false, max = 64 },
        x = { type = 'number', required = true },
        y = { type = 'number', required = true },
        z = { type = 'number', required = true },
        heading = { type = 'number', required = false, min = 0, max = 360 },
        radius = { type = 'number', required = false, min = 0.5, max = 50 },
        labelKey = { type = 'string', required = false, max = 128 },
    },

    PlacementUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        kind = { type = 'enum', required = false, values = { 'station_terminal', 'property_terminal', 'lab_terminal', 'booking_terminal', 'dispatch_console', 'courthouse_terminal', 'motorpool', 'evidence_bench' } },
        interaction = { type = 'enum', required = false, values = { 'prop', 'ped', 'zone' } },
        model = { type = 'string', required = false, max = 64 },
        x = { type = 'number', required = false },
        y = { type = 'number', required = false },
        z = { type = 'number', required = false },
        heading = { type = 'number', required = false, min = 0, max = 360 },
        radius = { type = 'number', required = false, min = 0.5, max = 50 },
        labelKey = { type = 'string', required = false, max = 128 },
        enabled = { type = 'boolean', required = false },
    },

    PlacementDelete = {
        id = { type = 'integer', required = true, min = 1 },
    },

    ChatSend = {
        body = { type = 'string', required = true, min = 1, max = 512 },
    },

    ChatHistory = {
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    RoleMapList = {
        agencyId = { type = 'string', required = false, max = 32 },
    },

    RoleMapCreate = {
        discordRoleId = { type = 'string', required = true, min = 17, max = 32 },
        discordRoleName = { type = 'string', required = false, max = 191 },
        groupKey = { type = 'string', required = true, max = 64 },
        agencyId = { type = 'string', required = true, max = 32 },
    },

    RoleMapDelete = {
        id = { type = 'integer', required = true, min = 1 },
    },

    FleetList = {
        placementId = { type = 'integer', required = true, min = 1 },
    },

    GarageDraw = {
        placementId = { type = 'integer', required = true, min = 1 },
        model = { type = 'string', required = true, max = 64 },
    },

    GarageReturn = {
        placementId = { type = 'integer', required = true, min = 1 },
        plate = { type = 'string', required = true, max = 16 },
    },
}
