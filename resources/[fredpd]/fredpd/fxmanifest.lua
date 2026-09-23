fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd'
description 'FredPD core: sessions, permissions, records, dispatch, property room, lab, court, personnel, NUI host'
author 'Rami'
version '0.0.0'
repository 'https://github.com/Admin-Chatterly/FredPD'

dependencies {
    'ox_lib',
    'oxmysql',
    'es_extended',
}

shared_scripts {
    '@ox_lib/init.lua',
    'config/shared.lua',
    'shared/init.lua',
    'shared/arrays.lua',
    'shared/generated/schema.lua',
    'shared/locale.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    -- Server-only. Never list this in files {}: it carries the gateway secret
    -- and anything else a client must not see (invariant 7).
    'config/server.lua',

    -- Bridges load first: core and modules call them during boot.
    'server/bridges/framework.lua',
    'server/bridges/policejob.lua',
    'server/bridges/society.lua',
    -- Section 8 reads both of these on every sensor call: the weapon behind a
    -- casing and the glove state behind a print (8.3.2). Unlisted, they are not
    -- merely absent -- the forensics routes degrade silently and the server
    -- generates no evidence at all.
    'server/bridges/inventory.lua',
    'server/bridges/appearance.lua',
    -- The gateway link (spec 3.7, C4). Pure crypto and the HTTP client only --
    -- no database, so it loads with the other bridges. `sha256` before `hmac`
    -- before `client`: each reads the namespace the one before it fills.
    'server/bridges/gateway/sha256.lua',
    'server/bridges/gateway/hmac.lua',
    'server/bridges/gateway/client.lua',

    -- Core, in dependency order. route.lua last: it references the rest.
    'server/core/db.lua',
    'server/core/audit.lua',
    'server/core/validate.lua',
    'server/core/ratelimit.lua',
    'server/core/agencies.lua',
    -- Before perms: it fills the table perms reads (ADR-010).
    'server/core/discord.lua',
    'server/core/perms.lua',
    'server/core/session.lua',
    'server/core/push.lua',
    'server/core/placements.lua',
    'server/core/counters.lua',
    'server/core/pagination.lua',
    'server/core/route.lua',
    -- The gateway outbox (spec 3.7). After `core/db.lua`, which it reads;
    -- physically under `server/bridges/gateway/` alongside the rest of the
    -- link, but loaded here because this is the first point the database
    -- wrapper it needs actually exists.
    'server/bridges/gateway/repo.lua',
    'server/bridges/gateway/service.lua',

    -- Modules: service (logic) and repo (SQL) before the routes that use them.

    -- Record-level access (spec 4.5) comes before every module that reads a
    -- record, because all of them ask it the same question.
    'server/modules/access/service.lua',
    'server/modules/access/repo.lua',

    -- The registers (spec 7.2-7.5). Persons first: the vehicle and firearm
    -- registers both resolve an owner through it.
    'server/modules/persons/repo.lua',
    'server/modules/persons/routes.lua',
    'server/modules/registry/service.lua',
    'server/modules/registry/repo.lua',
    'server/modules/registry/routes.lua',

    -- Suggests real citizens and vehicles from ESX's own tables while
    -- registering one (server/bridges/framework.lua). Routes only: the SQL
    -- lives in the bridge, because it is the bridge's schema to know, not a
    -- FredPD-owned table this module would otherwise keep a repo.lua for.
    'server/modules/esxdata/routes.lua',

    -- The unified query (spec 7.2) reads all three registers, so it loads last.
    'server/modules/query/service.lua',
    'server/modules/query/repo.lua',
    'server/modules/query/routes.lua',

    -- Brottskatalogen (spec 7.10). Loads before every module that writes a
    -- record, because a charge is a reference into this catalogue and the
    -- modules that hold charges read `brott.straffskala` and
    -- `brott.expandCharges` through its service.
    'server/modules/brott/service.lua',
    'server/modules/brott/repo.lua',
    'server/modules/brott/routes.lua',

    -- Anmälan och förundersökning (spec 7.7, 7.8). After brott, whose service
    -- it reads for the straffskala and the charge expansion, and after access,
    -- whose two halves every read here goes through.
    'server/modules/anmalan/service.lua',
    'server/modules/anmalan/repo.lua',
    'server/modules/anmalan/routes.lua',

    -- Frihetsberövande (spec 7.9). After anmalan, whose förundersökning a
    -- chain links to, and after brott, whose catalogue it charges from.
    'server/modules/frihet/service.lua',
    'server/modules/frihet/repo.lua',
    'server/modules/frihet/routes.lua',

    -- Tvångsmedel och efterlysning (spec 7.12, 7.13). After frihet, whose
    -- chain an efterlysning links to.
    'server/modules/tvangsmedel/service.lua',
    'server/modules/tvangsmedel/repo.lua',
    'server/modules/tvangsmedel/routes.lua',
    -- Events last: the handler reads the repo above it.
    'server/modules/tvangsmedel/events.lua',

    -- Spaningsuppdrag (spec 7.13). The operational lookout, as distinct from
    -- the efterlysning above it.
    'server/modules/spaning/service.lua',
    'server/modules/spaning/repo.lua',
    'server/modules/spaning/routes.lua',
    'server/modules/spaning/events.lua',

    -- Surveillance (spec 9, M5). The secret, tingsrätt-decided measures --
    -- after frihet, whose capacity-derivation pattern `capacityOf` follows,
    -- and after anmalan, whose förundersökning every request links to.
    'server/modules/surveillance/service.lua',
    'server/modules/surveillance/repo.lua',
    'server/modules/surveillance/routes.lua',

    -- Åtal och dom (spec 7.20, M6). After anmalan (reads FU rows through its
    -- repo) and after brott (charges and sentencing arithmetic).
    'server/modules/court/service.lua',
    'server/modules/court/repo.lua',
    'server/modules/court/routes.lua',

    -- Personnel (spec 7.22-7.24, M6). Reads `fpd_officers` (0001) and the
    -- firearms registry (0005), so it loads after `registry`.
    'server/modules/personnel/service.lua',
    'server/modules/personnel/repo.lua',
    'server/modules/personnel/routes.lua',

    -- Booking (spec 7.9, M6). After frihet, whose gripande and häktning rows
    -- it reads.
    'server/modules/booking/service.lua',
    'server/modules/booking/repo.lua',
    'server/modules/booking/routes.lua',

    -- Ordningsbot (spec 7.11, M6). After brott, whose versioned-catalogue
    -- pattern its tariff table follows.
    'server/modules/ordningsbot/service.lua',
    'server/modules/ordningsbot/repo.lua',
    'server/modules/ordningsbot/routes.lua',

    -- Impound (spec 7.15, M6). After spaning, whose `fredpd:vehicleImpounded`
    -- handler (already wired in `spaning/events.lua`, waiting on this module)
    -- it fires.
    'server/modules/impound/service.lua',
    'server/modules/impound/repo.lua',
    'server/modules/impound/routes.lua',

    'server/modules/placements/service.lua',
    'server/modules/placements/repo.lua',
    'server/modules/placements/routes.lua',
    'server/modules/chat/service.lua',
    'server/modules/chat/repo.lua',
    'server/modules/chat/routes.lua',
    'server/modules/garage/service.lua',
    'server/modules/garage/repo.lua',
    'server/modules/garage/routes.lua',
    -- The uncollected-trace grid (8.3.5). service before grid, because the
    -- grid reads `evidence.shouldMerge` and the forensics settings at load;
    -- routes last, because they need the grid and the route layer.
    'server/modules/forensics/service.lua',
    'server/modules/forensics/grid.lua',
    -- GSR after service (it reads the decay settings) and before routes (the
    -- shot sensor marks a shooter and the washing route clears them).
    'server/modules/forensics/gsr.lua',
    'server/modules/forensics/routes.lua',

    'server/modules/evidence/service.lua',
    'server/modules/evidence/repo.lua',
    'server/modules/evidence/routes.lua',
    'server/modules/intel/service.lua',
    'server/modules/intel/repo.lua',
    'server/modules/intel/routes.lua',
    -- Dispatch (spec 7.16-7.18). The order is load-bearing and the wiring check
    -- enforces it: each of these binds the namespace the one above publishes at
    -- load, not at call time -- `repo` reads `FredPD.Modules.cad`, `board` reads
    -- the repo, `avl` reads both the repo and the service, and `routes` reads
    -- `FredPD.Cad.avl` and `FredPD.Cad.board`.
    'server/modules/cad/service.lua',
    'server/modules/cad/repo.lua',
    -- Before `avl`, and that position is the whole point of the file. A board
    -- row carries the call its unit is on, so every payload that ships one has
    -- to mask it for readers refused that call (invariant 4) -- and `avl`,
    -- `routes` and `events` all ship one. The rule used to be a local in
    -- `routes.lua`; two of the three other senders did not apply it, and one of
    -- them un-masked what the first had masked. Loaded here it is reachable
    -- from all three at load. It reads `FredPD.Cad.avl` back, to invalidate the
    -- cached board, and does it inside a function body precisely because that
    -- file is listed below rather than above.
    'server/modules/cad/board.lua',
    'server/modules/cad/avl.lua',
    'server/modules/cad/routes.lua',
    -- Sign-on, last of the four: it binds the repo, the service and
    -- `FredPD.Cad.avl` at load, and it is the only thing that writes an
    -- `fpd_units` row. Listed after `routes.lua` rather than before it because
    -- nothing in the routes needs it -- they read the row it writes -- and a
    -- file that fills a namespace nobody reads at load is free to go last.
    'server/modules/cad/events.lua',

    'server/modules/admin/service.lua',
    'server/modules/admin/routes.lua',
    'server/modules/admin/bootstrap.lua',
    'server/modules/admin/superuser.lua',

    'server/main.lua',
}

client_scripts {
    'client/bridges/ui.lua',
    'client/bridges/garage.lua',
    'client/core.lua',
    'client/placements.lua',
    'client/placement-editor.lua',
    'client/chat.lua',
    'client/garage.lua',
    'client/fingerprint_scanner.lua',
    -- Dispatch: the panic keybind and the relay that carries the server's
    -- `fredpd:cad:*` pushes into the NUI. After `client/core.lua`, whose
    -- namespace it binds at load; before `client/main.lua`, which stays last
    -- because it is the NUI host and registers the terminal placements --
    -- `dispatch_console` among them -- that this file deliberately leaves alone.
    'client/cad.lua',
    'client/main.lua',
}

ui_page 'web/dist/index.html'

files {
    'web/dist/index.html',
    'web/dist/assets/*.js',
    'web/dist/assets/*.css',
    'locales/*.json',
}
