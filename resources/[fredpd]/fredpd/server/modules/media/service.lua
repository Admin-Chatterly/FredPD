--- The media ledger (spec 3.7, 9, 13.2; ADR-019): the pure part.
---
--- No natives, no database (`spec/media_spec.lua`).

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Media = {}

--- How long a begun upload may wait for its commit, in seconds. Longer than
--- the gateway's upload link (300 s by default), so an upload that made it in
--- time is never refused at the last step for being slow.
Media.PENDING_SECONDS = 900

local PHOTO_KINDS <const> = { mugshot = true, field = true, scar = true, mark = true, tattoo = true }

function Media.isPhotoKind(kind)
    return PHOTO_KINDS[kind] == true
end

--- Which permission a photograph of this kind is taken under. A mugshot is
--- the booking terminal's (`booking.intake`, 7.9); everything else is the
--- record's own (`rms.person.photo.upload`, 7.3). Asked again at commit, so
--- a grant lost between the two steps stops the second.
function Media.permissionFor(kind)
    if kind == 'mugshot' then return 'booking.intake' end
    return 'rms.person.photo.upload'
end

--- Is a media ref of the shape the gateway issues? Anything else is refused
--- before it reaches SQL or the gateway.
function Media.isRef(value)
    return type(value) == 'string' and #value <= 64 and value:match('^media_[%x%-]+$') ~= nil
end

FredPD.Modules.media = Media

return Media
