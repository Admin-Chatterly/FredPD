--- Record numbering (spec 13.1, Appendix D; invariants 1 and 8).
---
--- Every human-readable number in FredPD -- a person's `P-000431`, a scene's
--- `LSPD-S-2026-0042`, a report, a case, a warrant, a BOLO -- is allocated here,
--- from `fpd_counters`, inside the transaction that writes the record.
---
--- ## Why this file exists
---
--- Spec 13.1 has always said "numbers generated from `fpd_counters` inside a
--- transaction with a row lock". The table did not exist until migration 0005,
--- so the evidence module allocated the only other way available: an
--- `INSERT ... SELECT` whose subquery took `MAX(sequence) + 1` from the table it
--- was inserting into.
---
--- That reads as atomic and is not. Source and target are the same table, so
--- under REPEATABLE READ InnoDB takes next-key locks over the rows the subquery
--- scans and it mostly serialises. Under READ COMMITTED it takes no gap locks
--- and the scanning half is an ordinary consistent read: two officers opening a
--- scene in the same tick read the same MAX, compute the same sequence, and the
--- unique index refuses one of them in front of the officer. READ COMMITTED is
--- the default on several managed MariaDB products and is set outright on many
--- ESX servers, and the isolation level is the operator's to choose -- so the
--- allocation must not depend on it.
---
--- A counter row held under an exclusive lock behaves identically under every
--- isolation level. That is the whole idea.
---
--- ## The four statements
---
---   1. **Seed.** `INSERT ... ON DUPLICATE KEY UPDATE next_value = next_value`
---      creates the row for this (agency, kind, year) or, when it is already
---      there, takes an **exclusive** lock on it.
---
---      Not `INSERT IGNORE`: on a duplicate that takes a *shared* lock, which
---      step 2 would then have to upgrade, and two transactions each holding S
---      and each waiting for X is a deadlock. `ON DUPLICATE KEY UPDATE` takes X
---      straight away.
---
---   2. **Lock.** `SELECT next_value ... FOR UPDATE`. Redundant for us, because
---      step 1 already holds the lock, and kept deliberately: it is the
---      statement spec 13.1 names, it costs one primary-key lookup, and it means
---      the correctness of every record number does not rest on the reader
---      knowing MariaDB's duplicate-key locking by heart.
---
---   3. **The caller's statements.** The INSERT that writes the record reads the
---      locked counter through `Counters.numberSql()`.
---
---   4. **Bump.** `next_value = next_value + 1`, so the row holds the number the
---      *next* record will take.
---
--- All four in one `db.transaction`, which is what makes the lock cover the
--- read. A transaction should allocate one number: two counters locked in one
--- transaction, in an order two call sites disagree about, is how a deadlock
--- gets invented.
---
--- ## What this file is not
---
--- It does not decide what a number looks like. The format lives with the
--- module that owns the record -- `Evidence.numberPrefix` builds
--- `LSPD-2026-` and the width `6` -- so there is one definition of each format
--- and busted tests it. This file supplies the sequence and nothing else.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Counters = {}

--- The kinds of record that draw a number.
---
--- An allowlist in code rather than a CHECK in the schema (migration 0005 says
--- why): a typo'd kind must fail loudly at the call site, and adding a record
--- type must not need an ALTER in a new migration before the first record can
--- be written. Add a kind here when the module that uses it is written.
local KINDS <const> = {
    person = true,
    report = true,
    case = true,
    -- An intelligence case's own sequence (0023, Appendix D). Distinct from
    -- `case`, which is the förundersökning's kind: two record types sharing
    -- one counter would put both numbers in a sequence unreadable back to
    -- either.
    intel_case = true,
    warrant = true,
    bolo = true,
    arrest = true,
    citation = true,
    booking = true,
    call = true,
    scene = true,
    evidence = true,
    lab_request = true,
    impound = true,
    hak = true,
    atal = true,
    ia_case = true,
    -- A printed document (7.28, 0039): its own number, printed on every page.
    document = true,
}

--- The `year` value for a sequence that is not year-scoped.
---
--- A master person number is `P-{######}` with no year in it (Appendix D), so
--- it counts in one unbroken sequence per agency. A zero rather than a NULL
--- because the column is part of the primary key.
Counters.YEARLESS = 0

--- The year a number allocated now belongs to.
---
--- `os.date` is the Lua standard library rather than a native, so this file
--- stays loadable outside FXServer.
function Counters.year()
    return tonumber(os.date('%Y'))
end

function Counters.isKind(kind)
    return KINDS[kind] == true
end

local function assertKind(kind)
    assert(KINDS[kind], 'unknown counter kind: ' .. tostring(kind))

    return kind
end

--- The scalar subquery that turns the locked counter into a record number.
---
--- Written as a subquery in the INSERT's VALUES list rather than as
--- `INSERT ... SELECT`, so the statement that writes a record still reads as one
--- row of values with one expression in it, and so the counter is the only table
--- the read touches -- a primary-key lookup, whatever the size of the table
--- being written to. The old `MAX()` form scanned the target table behind an
--- unindexed LIKE and got slower every day the server ran (spec 12).
local NUMBER_SQL <const> = [[(SELECT CONCAT(?, LPAD(c.next_value, ?, '0'))
                               FROM fpd_counters c
                              WHERE c.agency_id = ? AND c.kind = ? AND c.year = ?)]]

--- The SQL fragment to place where the number column's value goes.
function Counters.numberSql()
    return NUMBER_SQL
end

--- The five values `numberSql()` consumes, in order.
---
--- A fresh table every call, so a caller can append the rest of its row to it.
--- Nothing here is nullable: a nil in an oxmysql values list silently shortens
--- the list and shifts every placeholder after it.
---
--- @param prefix string the fixed half of the number, from the owning module
--- @param width number how wide the sequence is padded
--- @param kind string
--- @param agencyId string from the session, never from input (invariant 1)
--- @param year number|nil defaults to this year; `Counters.YEARLESS` for none
--- @return table values
function Counters.numberValues(prefix, width, kind, agencyId, year)
    assertKind(kind)

    return { prefix, width, agencyId, kind, year or Counters.year() }
end

--- Wraps a caller's statements in the seed, the lock and the bump.
---
--- The result goes straight to `db.transaction`, so the whole allocation and the
--- write that uses it commit or roll back together: a number handed out to a
--- record that was never written is a gap in the sequence, and a record written
--- with a number the counter never moved past is a duplicate waiting to happen.
---
--- @param kind string
--- @param agencyId string
--- @param year number|nil
--- @param statements table the caller's { query, values } list
--- @return table the full transaction
function Counters.transaction(kind, agencyId, year, statements)
    assertKind(kind)

    year = year or Counters.year()

    local out = {
        {
            -- Creates the row, or takes the exclusive lock on it. See the
            -- header for why this is not `INSERT IGNORE`.
            query = [[INSERT INTO fpd_counters (agency_id, kind, year, next_value)
                      VALUES (?, ?, ?, 1)
                      ON DUPLICATE KEY UPDATE next_value = next_value]],
            values = { agencyId, kind, year },
        },
        {
            -- The lock spec 13.1 names. Held until this transaction commits, so
            -- everything after it reads a counter nobody else can move.
            query = [[SELECT next_value FROM fpd_counters
                       WHERE agency_id = ? AND kind = ? AND year = ?
                       FOR UPDATE]],
            values = { agencyId, kind, year },
        },
    }

    for index = 1, #statements do
        out[#out + 1] = statements[index]
    end

    out[#out + 1] = {
        query = [[UPDATE fpd_counters SET next_value = next_value + 1
                   WHERE agency_id = ? AND kind = ? AND year = ?]],
        values = { agencyId, kind, year },
    }

    return out
end

--- What the next number of this kind would be, without taking it.
---
--- For an administration screen showing where a sequence has got to. Never for
--- allocating: reading a counter outside a transaction is exactly the race this
--- module exists to remove.
---
--- @return number
function Counters.peek(kind, agencyId, year)
    assertKind(kind)

    return FredPD.Core.db.scalar(
        'SELECT next_value FROM fpd_counters WHERE agency_id = ? AND kind = ? AND year = ?',
        { agencyId, kind, year or Counters.year() }
    ) or 1
end

FredPD.Core.counters = Counters
