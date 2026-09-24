# ADR-019: Photographs through the gateway

- **Status:** Accepted
- **Date:** 2026-09-24
- **Spec:** 3.7, 7.3, 7.9, 9 (invariant 9), 11.2, 13.2

## Context

`fpd_person_photos` has existed since 0005, but no route wrote to it, and
`rms.person.photo.upload` guarded nothing. The gateway could already issue
upload and download tokens, store files and make thumbnails. Nothing on the
FiveM side called it, and the gateway itself had gaps:

- an upload token could be used more than once;
- it stored whatever bytes arrived, without re-encoding them, which invariant 9
  requires;
- it served every file as `application/octet-stream`;
- it had no CORS answer, so a PUT from the NUI would never be sent.

## Decision

- **Three steps, and the server owns the first and the last.**
  - *Begin*: the server reads the person, asks the gateway for an image
    upload link, and records the request in a new ledger, `fpd_media`
    (0038).
  - The NUI uploads the bytes.
  - *Commit*: the server attaches the file to the person. It does this only
    for a ref it issued to this officer, still pending and within 15 minutes,
    whose file the gateway holds, for a person the officer may still read.
  - A ref typed in by hand, or issued to someone else, is refused.
- **The gateway re-encodes every photograph.**
  - The file is decoded by sharp and written out as a fresh JPEG. That
    strips EXIF, rejects anything that is not an image, caps the longest
    side at 2048 px, and refuses decompression bombs.
  - An image upload is its own token action (`upload_image`), so a
    photograph token cannot be spent as a plain upload.
  - Every upload token is single-use:
    - the file is linked into place, never renamed over an existing one;
    - a refused upload leaves a tombstone, so the same link cannot try again.
  - The scan and the re-encode run on the unpublished part file. Nothing is
    servable that sharp did not produce.
  - Only JPEG, PNG and WebP reach the decoder. Input is capped at 16 M
    pixels, and at most two images are decoded at once.
  - Request logs drop the query string, which is the token.
  - Downloads are served with their real content type and `nosniff`.
  - CORS allows the NUI's origin (`https://cfx-nui-fredpd`, configurable)
    and nothing else.
- **FXServer signs download links itself.** A download token is an HMAC
  with a key derived from the shared secret. `Gateway.downloadUrl` computes
  the same HMAC in Lua, pinned in busted against a vector computed by Node,
  so opening a record with six photographs costs no HTTP calls. The link
  lasts `mediaLinkSeconds` (15 minutes). A reader gets links only for the
  photographs they may read, and the raw ref never leaves the server.
- **Mugshots are taken at the booking terminal.**
  - `booking.mugshot.begin` applies the ten-print's rules: the
    `accessPoint`, the range, and the check that the player standing at
    the terminal does not conflict with the person the booking names.
  - The client points a scripted camera at the player's head and takes
    the picture.
  - The permission is `booking.intake`, which patrol already holds.
  - A mugshot cannot be begun from the record. Field, scar, mark and
    tattoo photographs can, under `rms.person.photo.upload`, now granted
    to patrol.
- **screenshot-basic is an optional bridge** (`client/bridges/screenshot.lua`).
  Without it a photograph is refused with a sentence saying why, and records
  keep what they have. While the picture is taken the MDT is hidden, not
  closed, so no form loses what was typed.

## Consequences

- The server cannot prove the uploaded bytes are an in-game screenshot. An
  officer holding an upload link can PUT any picture; the gateway guarantees
  only that what it keeps is a re-encoded image. The commit, the audit entry
  and the identity checks at the terminal are what bind it to a person.
- Each officer may have five uploads begun and not committed at a time. A
  commit that loses a race with another commit of the same ref is refused,
  not reported as its own.

- Photographs need the gateway on, `VITE_MEDIA_HOST` set to its public media
  address at NUI build time (the CSP), and screenshot-basic installed. Without
  any of the three, everything else works and the button explains itself.
- An upload begun and never committed leaves a pending ledger row and possibly
  a file. The retention sweep (13.3) is where those are cleared.
- Scene photographs (8.4) and intelligence uploads can reuse the same
  ledger. `fpd_media.purpose` is a CHECK list that grows with them.
