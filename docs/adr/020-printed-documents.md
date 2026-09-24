# ADR-020: Printed documents are copies

- **Status:** Accepted
- **Date:** 2026-09-24
- **Spec:** 7.28, 3.7, 4.5, 9 (invariant 10)

## Context

Spec 7.28 asks for printable forms, with letterhead, page numbers, a document
number and a classification watermark. It also asks for an in-game paper item
that opens a read-only viewer while "access to the original stays controlled".

The gateway could already render a PDF from editor JSON, but nothing called it,
and the rendered pages had none of those marks. A paper copy has a further
problem: whoever is handed it must be able to read it. That includes a driver
given their citation, who has no MDT session. A route that let them read the
record would break invariant 4, and the rule that public routes never touch
a record.

## Decision

- **A printed document is a copy.** The module that owns the record builds
  its printed form: the citation (ordningsbot), the anmälan, and the custody
  log (frihetsberövande).
  - Each builder is a *printer* that module registers with
    `FredPD.Modules.documents`. It reads the record through the module's
    own access check and its own view permission, and it names people and
    vehicles only when the officer may read them.
  - The documents module never reads another module's tables.
- **Every print is kept.** `fpd_documents` (0039) stores the number, what was
  printed and by whom, and the printed content itself. The number follows
  Appendix D: `{AGENCY}-D{YY}-{######}`. The route is audited.
- **Paper carries its own content.**
  - The ox_inventory item's metadata holds the document as printed, cut at
    6,000 characters, with the cut marked.
  - Using the item opens the viewer from that metadata, with no server
    read, for whoever holds it.
  - The copy says what the record said when it was printed. The record
    stays behind its own access check.
  - The viewer parses the metadata as untrusted input and renders text only
    (invariant 10). A forged paper is possible, just as it is with real
    paper. The paper is not proof: the record in the MDT is, read through
    its own access check.
- **Paper has a ceiling (amended after review).** A paper leaves the access
  domain for good. It can be handed over, dropped, stolen or searched.
  Whoever holds it reads it with no session, no clearance and no audit, and
  ox_inventory sends item metadata to any client that opens the inventory.
  So only a record at or below `documents.paperCeiling` (default
  `internal`) may go to paper. It must also be in no compartment, not
  sealed, and not opened through a break-glass grant. A record with no
  classification the server recognises gets no copy at all.
- **A PDF is optional.**
  - It needs the gateway.
  - The gateway now prints the letterhead and the classification at the
    head of every page, and the document number, the printer and "page n
    / m" at the foot.
  - A faint classification watermark repeats on every sheet.
  - The officer gets a signed link (ADR-019), valid for
    `gateway.mediaLinkSeconds`. It is a **bearer link**: it is not tied to
    the officer, and anyone who has it can fetch the file until it expires.
  - A PDF of a restricted record (above `internal`, compartmented or sealed)
    is an export (11.1). It needs `document.export.restricted`, which is
    granted to supervisors and investigators, not to all of patrol. The
    print's audit row names the classification.
  - The render happens now or not at all. It never goes through the
    outbox: a retry after the officer was told nothing was printed would
    leave a file that no document row points at.
- **Preview first (6.4).** `document.preview` runs the same printer and
  shows the page and which copies may be made, and why not. It numbers and
  keeps nothing. The print is committed from the preview.
- **Permission:** `document.print`, granted to `patrol_basic`, plus the
  record's own view permission, asked again by its printer.
- **Only readable people are named.** The anmälan's printer names only the
  people the officer may read. A protected witness is left off, and so is
  the count of who was left off.

## Consequences

- Paper needs one item in the server's ox_inventory list (installation guide,
  11d). Without it only the PDF is offered, and without the gateway only
  paper. The screen offers what `document.capabilities` says exists.
- A document keeps a record's content after the record changes, which is the
  point of a copy. Retention (13.3) should treat `fpd_documents` like the
  record it was printed from.
