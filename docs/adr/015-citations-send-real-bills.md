# ADR-015: A citation sends a real bill, and learns it was paid

- **Status:** Accepted
- **Date:** 2026-09-24
- **Spec:** 3.8, 7.11

## Context

An ordningsbot citation was a record and nothing more. The fined player was
never asked for the money, and the citation was marked paid only if an officer
remembered to press "Mark paid". Spec 7.11 recorded the billing bridge as not
built. In play this made a fine paperwork that led to nothing, which is the
opposite of what the owner asked the suite to be.

The server runs esx_billing. Its whole server-side surface is
`BillPlayerByIdentifier(target, sender, account, label, amount)`, which returns
nothing, writes its row asynchronously, and deletes the row when the bill is
paid. It has no event for payment and no way to withdraw a bill.

## Decision

- **Issuing a citation sends a bill** through a new `billing` bridge. It goes to
  the person the citation names, or the registered keeper of the vehicle, and is
  paid into the agency's society account. Nothing is sent when billing is off,
  when esx_billing is not started, or when nobody identifiable can be billed.
- **The bridge finds the bill it just sent**, and the label alone is not enough
  to do it. Players can write bills too: `esx_billing:sendBill` is a client
  event and accepts any label. So a player could pre-create a 1 kr bill to
  themselves carrying the next citation number, pay it, and have the fine read
  as paid. The row is therefore matched on everything FredPD controls and a
  player's own bill cannot carry:
  - it is newer than the table's highest id before sending;
  - it is from the issuing officer, to the agency's society, for the tariff amount;
  - it has the citation's label.

  Two matches are ambiguous and count as not sent. The bill's id and label are
  stored on the citation (`fpd_ordningsbot.bill_id`, `bill_label`, migration
  0031). A bill that never appears counts as not sent.
- **Only a `society_*` account is billed.** esx_billing pays any other account
  to the bill's sender, which here is the issuing officer.
- **A bill leaving esx_billing's table marks the citation paid.** A server
  thread does this and audits it as automatic. It is keyed on the bill id, so a
  failed read of that table never counts as paid.
- **Voiding, contesting or manually paying a citation deletes its bill** from
  esx_billing's table. This is the one write FredPD makes into another
  resource's table in this ADR. It is confined to the bridge, and it only
  touches a row the bridge itself created: a voided fine must not stay payable,
  and esx_billing offers no other way to withdraw one. The delete matches id
  *and* label, so a stale id cannot delete another player's bill after
  esx_billing's table has been truncated. Every withdrawal is audited, including
  the ones that fail. The database user FredPD connects as therefore needs
  `SELECT` and `DELETE` on esx_billing's table.
- `ordningsbot.pay` stays as a manual path, for citations that sent no bill or
  were settled another way.

## Consequences

- Paying a fine needs no one at the MDT. The issuing officer is told when it is
  paid.
- FredPD depends on esx_billing's table shape (`id`, `identifier`, `sender`,
  `target_type`, `target`, `label`, `amount`),
  named once in config (`billing.table`). A fork with a different shape needs a
  second implementation of the bridge contract, not changes across modules.
- A bill deleted by an administrator by hand reads as paid. This is accepted:
  in esx_billing a row disappearing is what payment looks like, and the audit
  entry says the payment was detected automatically.

## Alternatives considered

- **Insert the bill row directly.** This would return an id at once, but it
  would bypass esx_billing's own society check and its notification to the
  player. Rejected in favour of the export, plus finding the row it wrote.
- **Wait for a payment event.** esx_billing emits none, so there is nothing to
  wait for.
- **Keep payment manual.** This is the status quo the owner asked to remove.
