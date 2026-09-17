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
    'server/core/route.lua',

    -- Modules: service (logic) and repo (SQL) before the routes that use them.
    'server/modules/placements/service.lua',
    'server/modules/placements/repo.lua',
    'server/modules/placements/routes.lua',
    'server/modules/chat/service.lua',
    'server/modules/chat/repo.lua',
    'server/modules/chat/routes.lua',
    'server/modules/garage/service.lua',
    'server/modules/garage/repo.lua',
    'server/modules/garage/routes.lua',
    'server/modules/evidence/service.lua',
    'server/modules/evidence/repo.lua',
    'server/modules/evidence/routes.lua',
    'server/modules/intel/service.lua',
    'server/modules/intel/repo.lua',
    'server/modules/intel/routes.lua',
    'server/modules/admin/service.lua',
    'server/modules/admin/routes.lua',
    'server/modules/admin/bootstrap.lua',

    'server/main.lua',
}

client_scripts {
    'client/bridges/ui.lua',
    'client/core.lua',
    'client/placements.lua',
    'client/placement-editor.lua',
    'client/chat.lua',
    'client/garage.lua',
    'client/main.lua',
}

ui_page 'web/dist/index.html'

files {
    'web/dist/index.html',
    'web/dist/assets/*.js',
    'web/dist/assets/*.css',
    'locales/*.json',
}
