# ADR-016: An impound takes the car off the street and out of the garage

- **Status:** Accepted
- **Date:** 2026-09-24
- **Spec:** 3.8, 7.15
- **Amends:** ADR-008, where it gives impound to p_policejob and says FredPD reads impound state and does not write it

## Context

ADR-008 left impound with p_policejob. Spec 7.15 was then built as FredPD's
own module (migration 0020), but only as a record. An officer who impounded a
car wrote a row, and the car stayed parked where it was. Its owner could drive
it away, or pull it out of their garage the next day. The impound meant nothing
in the game.

p_policejob's published server exports cover jail and evidence, not impound,
so there is nothing there to call.

## Decision

- **"Impound" on a car through ox_target** (`impound.tow`) records the impound
  and deletes the car. The client names only the entity and the reason. The
  server refuses the tow when:
  - the officer is further than `impound.world.range` metres away;
  - the car is in another routing bucket;
  - a player is in any seat (checked again immediately before the delete);
  - the car is an emergency vehicle or out on a motor-pool draw;
  - the same car is already being towed.
- **The garage is written only when a tow can vouch for the car.** A plate on
  the street is whatever the car's owning client set it to. So the owner's
  `owned_vehicles.stored` is set to `storedWhileImpounded` only when all of
  these hold:
  - the car was actually removed from the world;
  - the drawn plate matches exactly one garage row, compared byte for byte,
    never through the normalised form;
  - that row's model is the model of the car that was towed.

  It is also not marked if any other car in the world still carries that
  plate: that car is the real one or a clone, and a second copy must not come
  out of the garage later. Only a verified tow resolves a lookout on the
  vehicle. Any other tow is still an
  impound, but it touches nobody's garage.
- **The default held value is 2**, which esx_garage ignores. The car shows
  neither in the garage nor at the ESX pound, so the owner cannot pay the pound
  a flat fee and get round the hold. 0 ("out") would allow exactly that.
- **Release writes `storedOnRelease` (1)** only when all of these hold:
  - the impound recorded a tow that marked a garage row (`towed_at`,
    `garage_plate`, migration 0032);
  - no other open impound in any agency holds that plate;
  - the row still reads as held;
  - no car carrying that plate is in the world.

  Anything else would put a car "back in the garage" that is still on the
  street, which is a duplicated vehicle.
- **An impound made from the MDT is a record only.** It deletes nothing and
  writes no garage row, because the MDT does not know which car it means.
- The `owned_vehicles` read and write live only in the framework bridge. Its
  table and column names are config, checked at startup to be plain
  identifiers. Setting `esxData.vehicles.stored = nil` turns the write off.
- The tow's audit entry records the model, coordinates, net id, whether the
  plate was verified and whether the garage was marked.

## Consequences

- An impound is felt in play. The car is gone, and it is back in the garage
  when it is released.
- FredPD writes one column of ESX's `owned_vehicles`, so its database user needs
  `UPDATE` on that table.
- A car whose plate was swapped, or whose garage row stores no readable model
  (neither a hash nor a model name), is towed without its garage being marked. The hold is then a record plus a missing car.

## Alternatives considered

- **Hand impound to p_policejob.** It exposes no impound export to call.
- **Delete by plate from anywhere on the map.** This would reach cars nowhere
  near the officer, including one someone else is driving. Deleting only the
  entity the officer is looking at, and only when no player is in it, is the
  narrow version.
