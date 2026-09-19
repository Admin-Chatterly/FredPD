fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd_assets'
description 'FredPD assets: streamed props (MDC tablet, terminals, evidence bags, markers, tape) and sounds'
author 'Rami'
version '0.0.0'
repository 'https://github.com/Admin-Chatterly/FredPD'

-- Assets only: no scripts, so there is nothing here to exploit and nothing to
-- start in the wrong order. `stream/` is empty until the models land with the
-- milestone that needs them (evidence markers and bags in M3, terminals in M1).
this_is_a_map 'no'

files {
    'stream/**/*',
}
