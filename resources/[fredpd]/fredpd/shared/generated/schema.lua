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

--- Person of interest status (spec 10).
FredPD.IntelPersonStatus = {
    UNKNOWN = 'unknown',
    POI = 'poi',
    ACTIVE_INVESTIGATION = 'active_investigation',
    WARRANT = 'warrant',
    CLEARED = 'cleared',
    INCARCERATED = 'incarcerated',
    DECEASED = 'deceased',
}

--- Organisation type (spec 10).
FredPD.IntelOrgType = {
    GANG = 'gang',
    CARTEL = 'cartel',
    BUSINESS = 'business',
    CREW = 'crew',
    OTHER = 'other',
}

--- Organisation status (spec 10).
FredPD.IntelOrgStatus = {
    ACTIVE = 'active',
    DISBANDED = 'disbanded',
    DORMANT = 'dormant',
}

--- Where a piece of intelligence came from (spec 10).
FredPD.IntelSource = {
    INFORMANT = 'informant',
    WIRETAP = 'wiretap',
    SURVEILLANCE = 'surveillance',
    PATROL = 'patrol',
    TIP = 'tip',
    OTHER = 'other',
}

--- Confidence in a piece of intelligence (spec 10).
FredPD.IntelConfidence = {
    LOW = 'low',
    MEDIUM = 'medium',
    HIGH = 'high',
}

--- Case status (spec 10).
FredPD.IntelCaseStatus = {
    OPEN = 'open',
    CLOSED = 'closed',
    COLD = 'cold',
}

--- Record classification levels (spec 4.5).
FredPD.Classification = {
    OPEN = 'open',
    INTERNAL = 'internal',
    RESTRICTED = 'restricted',
    CONFIDENTIAL = 'confidential',
    SECRET = 'secret',
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

    GroupList = {

    },

    GroupCreate = {
        key = { type = 'string', required = true, min = 2, max = 64 },
        name = { type = 'string', required = true, min = 1, max = 191 },
        inherits = { type = 'string', required = false, max = 64 },
        description = { type = 'string', required = false, max = 255 },
        permissions = { type = 'string[]', required = true, maxItems = 256, maxLength = 128 },
    },

    GroupUpdate = {
        key = { type = 'string', required = true, min = 2, max = 64 },
        name = { type = 'string', required = false, min = 1, max = 191 },
        inherits = { type = 'string', required = false, max = 64 },
        description = { type = 'string', required = false, max = 255 },
        permissions = { type = 'string[]', required = false, maxItems = 256, maxLength = 128 },
    },

    GroupDelete = {
        key = { type = 'string', required = true, min = 2, max = 64 },
    },

    PermissionList = {

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

    FleetManage = {

    },

    FleetAdd = {
        model = { type = 'string', required = true, min = 1, max = 64 },
        labelKey = { type = 'string', required = true, min = 3, max = 128 },
        permission = { type = 'string', required = false, max = 128 },
        certification = { type = 'string', required = false, max = 64 },
        livery = { type = 'integer', required = false, min = -1, max = 63 },
        sortOrder = { type = 'integer', required = false, min = 0, max = 9999 },
        enabled = { type = 'boolean', required = false },
        requiredGroup = { type = 'string', required = false, max = 64 },
        requiredDiscordRole = { type = 'string', required = false, max = 32 },
    },

    FleetUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        model = { type = 'string', required = false, max = 64 },
        labelKey = { type = 'string', required = false, max = 128 },
        permission = { type = 'string', required = false, max = 128 },
        certification = { type = 'string', required = false, max = 64 },
        livery = { type = 'integer', required = false, min = -1, max = 63 },
        sortOrder = { type = 'integer', required = false, min = 0, max = 9999 },
        enabled = { type = 'boolean', required = false },
        requiredGroup = { type = 'string', required = false, max = 64 },
        requiredDiscordRole = { type = 'string', required = false, max = 32 },
    },

    FleetRemove = {
        id = { type = 'integer', required = true, min = 1 },
    },

    SceneCreate = {
        caseNumber = { type = 'string', required = false, max = 32 },
        radius = { type = 'number', required = false, min = 5, max = 500 },
    },

    SceneRelease = {
        id = { type = 'integer', required = true, min = 1 },
        reason = { type = 'string', required = false, max = 255 },
    },

    SceneList = {
        status = { type = 'enum', required = false, values = { 'open', 'released' } },
        caseNumber = { type = 'string', required = false, max = 32 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    EvidenceCollect = {
        traceKey = { type = 'string', required = true, min = 1, max = 64 },
        sceneId = { type = 'integer', required = false, min = 1 },
        caseNumber = { type = 'string', required = false, max = 32 },
        packaging = { type = 'enum', required = false, values = { 'envelope', 'swab_box', 'lift_card', 'bag', 'gsr_kit', 'tape_lift', 'cast', 'photo', 'field_test_kit', 'evidence_bag' } },
        markerNumber = { type = 'integer', required = false, min = 1, max = 999 },
        description = { type = 'string', required = false, max = 512 },
    },

    EvidenceList = {
        status = { type = 'enum', required = false, values = { 'collected', 'in_locker', 'in_property', 'checked_out', 'at_lab', 'released', 'destroyed' } },
        type = { type = 'enum', required = false, values = { 'print', 'blood', 'dna_touch', 'casing', 'bullet', 'magazine', 'gsr', 'footwear', 'glove_mark', 'drug_residue', 'tool_mark', 'digital' } },
        sceneId = { type = 'integer', required = false, min = 1 },
        caseNumber = { type = 'string', required = false, max = 32 },
        search = { type = 'string', required = false, max = 64 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    EvidenceGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    EvidenceCustody = {
        id = { type = 'integer', required = true, min = 1 },
    },

    EvidenceIntake = {
        placementId = { type = 'integer', required = true, min = 1 },
        id = { type = 'integer', required = true, min = 1 },
        accepted = { type = 'boolean', required = true },
        storageLocation = { type = 'string', required = false, max = 64 },
        reason = { type = 'string', required = false, max = 255 },
    },

    EvidenceTransfer = {
        id = { type = 'integer', required = true, min = 1 },
        destination = { type = 'enum', required = true, values = { 'locker', 'lab', 'court', 'investigator' } },
        toParty = { type = 'string', required = false, max = 191 },
        reason = { type = 'string', required = true, min = 1, max = 255 },
    },

    LabRequestCreate = {
        evidenceIds = { type = 'string[]', required = true, maxItems = 25, maxLength = 20 },
        analyses = { type = 'string[]', required = true, maxItems = 6, maxLength = 32 },
        priority = { type = 'enum', required = false, values = { 'routine', 'expedited', 'urgent' } },
        caseNumber = { type = 'string', required = false, max = 32 },
        justification = { type = 'string', required = false, max = 512 },
    },

    LabQueue = {
        status = { type = 'enum', required = false, values = { 'queued', 'in_progress', 'complete', 'reviewed', 'released', 'cancelled' } },
        analysis = { type = 'enum', required = false, values = { 'dna', 'print_comparison', 'print_search', 'ballistics', 'gsr', 'drug_id' } },
        mine = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    LabAnalysisStart = {
        id = { type = 'integer', required = true, min = 1 },
    },

    LabAnalysisComplete = {
        id = { type = 'integer', required = true, min = 1 },
        observations = { type = 'string', required = false, max = 1024 },
    },

    IntelId = {
        id = { type = 'integer', required = true, min = 1 },
    },

    IntelSearch = {
        term = { type = 'string', required = true, min = 2, max = 128 },
        perType = { type = 'integer', required = false, min = 1, max = 25 },
    },

    IntelPersonList = {
        search = { type = 'string', required = false, max = 128 },
        status = { type = 'enum', required = false, values = { 'unknown', 'poi', 'active_investigation', 'warrant', 'cleared', 'incarcerated', 'deceased' } },
        tag = { type = 'string', required = false, max = 64 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    IntelPersonCreate = {
        name = { type = 'string', required = false, max = 191 },
        alias = { type = 'string', required = false, max = 191 },
        description = { type = 'string', required = false, max = 4000 },
        status = { type = 'enum', required = false, values = { 'unknown', 'poi', 'active_investigation', 'warrant', 'cleared', 'incarcerated', 'deceased' } },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    IntelPersonUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        name = { type = 'string', required = false, max = 191 },
        alias = { type = 'string', required = false, max = 191 },
        description = { type = 'string', required = false, max = 4000 },
        status = { type = 'enum', required = false, values = { 'unknown', 'poi', 'active_investigation', 'warrant', 'cleared', 'incarcerated', 'deceased' } },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    IntelPersonMerge = {
        keepId = { type = 'integer', required = true, min = 1 },
        dropId = { type = 'integer', required = true, min = 1 },
    },

    IntelOrgList = {
        search = { type = 'string', required = false, max = 128 },
        tag = { type = 'string', required = false, max = 64 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    IntelOrgCreate = {
        name = { type = 'string', required = true, min = 1, max = 191 },
        type = { type = 'enum', required = false, values = { 'gang', 'cartel', 'business', 'crew', 'other' } },
        territory = { type = 'string', required = false, max = 191 },
        status = { type = 'enum', required = false, values = { 'active', 'disbanded', 'dormant' } },
        notes = { type = 'string', required = false, max = 4000 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    IntelOrgUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        name = { type = 'string', required = false, min = 1, max = 191 },
        type = { type = 'enum', required = false, values = { 'gang', 'cartel', 'business', 'crew', 'other' } },
        territory = { type = 'string', required = false, max = 191 },
        status = { type = 'enum', required = false, values = { 'active', 'disbanded', 'dormant' } },
        notes = { type = 'string', required = false, max = 4000 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    IntelNoteList = {
        personId = { type = 'integer', required = false, min = 1 },
        orgId = { type = 'integer', required = false, min = 1 },
        caseId = { type = 'integer', required = false, min = 1 },
        source = { type = 'enum', required = false, values = { 'informant', 'wiretap', 'surveillance', 'patrol', 'tip', 'other' } },
        confidence = { type = 'enum', required = false, values = { 'low', 'medium', 'high' } },
        tag = { type = 'string', required = false, max = 64 },
        search = { type = 'string', required = false, max = 128 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    IntelNoteCreate = {
        personId = { type = 'integer', required = false, min = 1 },
        orgId = { type = 'integer', required = false, min = 1 },
        caseId = { type = 'integer', required = false, min = 1 },
        body = { type = 'string', required = true, min = 1, max = 8000 },
        source = { type = 'enum', required = false, values = { 'informant', 'wiretap', 'surveillance', 'patrol', 'tip', 'other' } },
        confidence = { type = 'enum', required = false, values = { 'low', 'medium', 'high' } },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
        tags = { type = 'string[]', required = false, maxItems = 12, maxLength = 64 },
    },

    IntelNoteUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        body = { type = 'string', required = false, min = 1, max = 8000 },
        source = { type = 'enum', required = false, values = { 'informant', 'wiretap', 'surveillance', 'patrol', 'tip', 'other' } },
        confidence = { type = 'enum', required = false, values = { 'low', 'medium', 'high' } },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
        tags = { type = 'string[]', required = false, maxItems = 12, maxLength = 64 },
    },

    IntelVehicleCreate = {
        personId = { type = 'integer', required = false, min = 1 },
        plate = { type = 'string', required = false, max = 16 },
        model = { type = 'string', required = false, max = 64 },
        color = { type = 'string', required = false, max = 64 },
        notes = { type = 'string', required = false, max = 2000 },
    },

    IntelCaseList = {
        status = { type = 'enum', required = false, values = { 'open', 'closed', 'cold' } },
        search = { type = 'string', required = false, max = 128 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    IntelCaseCreate = {
        title = { type = 'string', required = true, min = 1, max = 191 },
        description = { type = 'string', required = false, max = 8000 },
        status = { type = 'enum', required = false, values = { 'open', 'closed', 'cold' } },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    IntelCaseUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        title = { type = 'string', required = false, min = 1, max = 191 },
        description = { type = 'string', required = false, max = 8000 },
        status = { type = 'enum', required = false, values = { 'open', 'closed', 'cold' } },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    IntelCaseLinkAdd = {
        caseId = { type = 'integer', required = true, min = 1 },
        personId = { type = 'integer', required = false, min = 1 },
        orgId = { type = 'integer', required = false, min = 1 },
        role = { type = 'string', required = false, max = 191 },
    },

    IntelMembershipSet = {
        personId = { type = 'integer', required = true, min = 1 },
        orgId = { type = 'integer', required = true, min = 1 },
        role = { type = 'string', required = false, max = 191 },
        isConfirmed = { type = 'boolean', required = false },
    },

    IntelMembershipRemove = {
        personId = { type = 'integer', required = true, min = 1 },
        orgId = { type = 'integer', required = true, min = 1 },
    },

    IntelAssociateSet = {
        personId = { type = 'integer', required = true, min = 1 },
        associateId = { type = 'integer', required = true, min = 1 },
        relationship = { type = 'string', required = false, max = 191 },
        isConfirmed = { type = 'boolean', required = false },
    },

    IntelAssociateRemove = {
        personId = { type = 'integer', required = true, min = 1 },
        associateId = { type = 'integer', required = true, min = 1 },
    },

    IntelEvidenceAdd = {
        personId = { type = 'integer', required = false, min = 1 },
        orgId = { type = 'integer', required = false, min = 1 },
        caseId = { type = 'integer', required = false, min = 1 },
        url = { type = 'string', required = false, max = 1024 },
        storagePath = { type = 'string', required = false, max = 512 },
        caption = { type = 'string', required = false, max = 512 },
    },
}
