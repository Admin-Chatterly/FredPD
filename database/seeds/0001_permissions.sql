-- Default permission groups (spec 4.3, Appendix B and C).
--
-- Seeds ship with the product and must be re-runnable without duplicating rows,
-- so every statement here is an upsert or an INSERT IGNORE.
--
-- These are the *bundles*. Which Discord role grants which bundle is not seeded:
-- role ids are specific to your guild, and that mapping is edited in the MDT
-- (spec 7.30). A fresh install therefore grants nobody anything until an
-- administrator maps the first role, which is the correct default -- and it is
-- also why a group you do not want is harmless: an unmapped group grants
-- nobody anything.
--
-- Groups here cover what exists today (M1, the records and forensics work of
-- M2 and M3, the intelligence register, and M4 dispatch). Later milestones add
-- their own. No new *group* was needed for dispatch: Appendix C already maps
-- the Dispatcher role to `dispatch`, and the officer half of CAD belongs to the
-- patrol groups that already exist.

-- -----------------------------------------------------------------------------
-- Platform groups
-- -----------------------------------------------------------------------------

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('patrol_basic', 'Patrol (trainee)', NULL,
     'A trainee: read the MDT and use the internal channel, nothing that changes a record.'),
    ('patrol',       'Patrol',           'patrol_basic',
     'A patrol officer: motor pool, queries, the internal channel.'),
    ('supervisor',   'Supervisor',       'patrol',
     'A field supervisor: everything patrol has, plus oversight.'),
    ('command',      'Command',          'supervisor',
     'Command staff.'),
    -- `dispatch` is a ROOT GROUP, and the NULL is load-bearing. It used to
    -- inherit `patrol_basic`, which meant every dispatcher held
    -- `cad.unit.status` -- the key `cad/events.lua` reads to decide who belongs
    -- on the unit board. The file compensated with a negative test (hold
    -- `cad.console.open` and you are disqualified), and that is the arrangement
    -- this row exists to be rid of: a grantable capability whose only effect
    -- anywhere was to take its holder off the board, and a union of roles that
    -- could never describe somebody who both dispatches and patrols. Now the
    -- split is the absence of a key rather than the presence of one. A
    -- dispatcher is not on the board because nothing grants them
    -- `cad.unit.status`; somebody holding the Dispatcher *and* Patrol roles
    -- gets it from the patrol half and is on the board, which is correct,
    -- because they really do patrol.
    --
    -- The four keys `dispatch` actually used from `patrol_basic` are granted
    -- to it directly below. The two it did not -- `cad.unit.status` and
    -- `cad.emergency` -- are the two that were unusable anyway: both handlers
    -- read the caller's `fpd_units` row and a console operator has none.
    --
    -- Re-running this seed on a server that ran the old one flips the edge:
    -- the statement's `inherits` = VALUES(`inherits`) below is an update, not
    -- an insert-only. That is deliberate, and it is the only part of this
    -- change that is not additive.
    ('dispatch',     'Dispatch',         NULL,
     'A dispatcher: the CAD console, the registers and the internal channel. Not a unit on the board.'),
    ('admin',        'FredPD administration', NULL,
     'Configures FredPD. Deliberately does NOT inherit patrol: administering the system is not the same as being cleared to read records.')
ON DUPLICATE KEY UPDATE
    -- `VALUES(col)` rather than MySQL 8's `AS new` row alias: MariaDB does not
    -- implement the alias form, and the spec targets MariaDB 11.4 (spec 3.3).
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

-- -----------------------------------------------------------------------------
-- Intelligence groups (spec 10, Appendix C)
--
-- The three mirror the RUE roles. What separates them is not how much they can
-- read -- an analyst reads the whole register -- but two specific powers:
-- seeing where protected intelligence came from, and destroying records.
--
-- A second statement rather than more rows above, because `inherits` is a
-- foreign key onto this same table: the platform groups must exist before
-- anything can inherit from them, and keeping the two sets apart makes the
-- dependency obvious.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Evidence, property and lab groups (spec 8)
--
-- Three roles rather than one, because section 8's whole point is that custody
-- passes between people who are accountable separately. The officer who
-- collects, the officer who stores and the analyst who tests are different
-- jobs, and a chain of custody where they are the same person proves nothing.
-- -----------------------------------------------------------------------------

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('evidence_tech', 'Crime scene technician', NULL,
     'Creates and processes scenes, collects evidence, uses forensic tools.'),
    ('property_officer', 'Property room officer', NULL,
     'Takes evidence into the property room, moves it, checks it in and out.'),
    ('lab_analyst', 'Forensic analyst', NULL,
     'Works the lab queue and performs analyses. Cannot release a report alone.'),
    ('lab_supervisor', 'Forensic supervisor', 'lab_analyst',
     'An analyst who may also technically review another analyst''s work and release the report.')
ON DUPLICATE KEY UPDATE
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

-- Utredare (investigator): the M3 lab work modelled it as a Discord role
-- separate from patrol, held by a dedicated forensic analyst. In practice an
-- investigating officer needs to start and read back their own analyses
-- without waiting on somebody mapped to `lab_analyst`, so this group carries
-- the same three lab grants on its own -- not inheriting `lab_analyst`,
-- because a department may map the two to different Discord roles and an
-- inheritance edge would tie their escalation checks together for no reason.
INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('utredare', 'Utredare', NULL,
     'An investigator: may submit, work and read the lab queue without a separate analyst role.')
ON DUPLICATE KEY UPDATE
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

-- -----------------------------------------------------------------------------
-- DOJ groups (spec 7.9, 7.12)
--
-- The prosecutor and the court. Separate groups rather than ranks inside the
-- department, because RB gives them decisions the police cannot take: an
-- åklagare anhåller, a domare häktar, and a förundersökning passes to the
-- prosecutor once a suspect is anhållen.
--
-- Neither inherits a police group. A prosecutor is not a senior officer, and a
-- server that mapped its DOJ Discord role onto `supervisor` would be giving the
-- court the power to approve the police reports it later reads.
-- -----------------------------------------------------------------------------

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('aklagare', 'Åklagare', NULL,
     'The prosecutor: leads a förundersökning, anhåller, decides on coercive measures.'),
    ('domare',   'Domare',   NULL,
     'The court: decides häktning, and the measures RB reserves to a judge.')
ON DUPLICATE KEY UPDATE
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('intel_analyst', 'Intelligence analyst', NULL,
     'Reads and writes the intelligence register. Cannot see protected sources and cannot delete.'),
    ('intel_handler', 'Source handler',       'intel_analyst',
     'An analyst who may also see where protected intelligence came from, and merge duplicate records.'),
    ('intel_command', 'Intelligence command', 'intel_handler',
     'A handler who may also delete records from the register.')
ON DUPLICATE KEY UPDATE
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

-- -----------------------------------------------------------------------------
-- Group -> permission keys
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    -- A trainee can look and can talk, and that is all.
    ('patrol_basic', 'page.records'),
    ('patrol_basic', 'page.comms'),
    ('patrol_basic', 'comms.pdchat.send'),
    ('patrol_basic', 'comms.pdchat.view'),

    -- `forensics.trace.report` was granted here and is gone on purpose. M3
    -- shipped it as the key a client's sensors reported through, which made
    -- leaving evidence behind a thing only an officer could do: 8.3.4 says the
    -- owner of a print is whoever left it, and that is usually not an officer,
    -- and 8.10 says destroying it is open to every player. A permissioned
    -- report route answered `no_session` to every criminal on the server, so
    -- the two world routes became public instead (ADR-013) and the key now
    -- guards nothing. It was never in the spec either -- Appendix B lists four
    -- forensics keys and this was not one of them.
    --
    -- Dropping a grant from a seed is safe where dropping a migration is not:
    -- this file is re-runnable upserts (see the header), not schema history. A
    -- database that already ran the old seed keeps its row, because the
    -- statement this comment sits inside is an INSERT IGNORE and nothing here
    -- deletes; that row is inert, since no route asks for the key any more.

    -- Patrol adds the motor pool and the vehicle they need to do the job.
    ('patrol', 'garage.vehicle.draw'),
    ('patrol', 'garage.vehicle.return'),
    ('patrol', 'query.person.run'),
    ('patrol', 'query.vehicle.run'),

    -- The unified query (7.2). Running one is the most ordinary thing an
    -- officer does, and confirming a hot-file hit is part of the same act: a
    -- hit is a lead until somebody confirms it, so an officer who can raise one
    -- and not confirm it can only ever act on unconfirmed leads.
    ('patrol', 'query.run'),
    ('patrol', 'query.hit.confirm'),

    -- Reading somebody else's query history is the misuse investigation, not
    -- ordinary work. Your own history needs no key beyond being able to query:
    -- the route asks for `query.person.run` and requires this one the moment
    -- the question stops being about the caller.
    ('command', 'query.log.view'),

    -- The registers (spec 7.2-7.5). Reading them is ordinary patrol work: an
    -- officer who may run a plate has to be able to open what the plate
    -- returns, or the query answers a question nobody can follow up.
    ('patrol', 'rms.person.view'),
    ('patrol', 'rms.vehicle.view'),
    ('patrol', 'rms.firearm.view'),

    -- Writing to them is not. Correcting a record of a real person, registering
    -- a vehicle or changing a plate are all things a department wants to be able
    -- to point at afterwards, so they sit a rank up.
    ('supervisor', 'rms.person.edit'),
    ('supervisor', 'rms.vehicle.edit'),
    ('supervisor', 'rms.vehicle.flag'),
    ('supervisor', 'rms.firearm.edit'),

    -- A caution is a safety flag on a person -- armed, violent, officer safety.
    -- Held apart from `rms.person.edit` because setting one wrongly follows
    -- somebody through every future stop.
    ('supervisor', 'rms.person.caution.edit'),

    -- Anmälan (spec 7.7). Reading and writing one is the core of patrol work:
    -- an officer who attends an incident writes the anmälan for it, and one who
    -- cannot read them cannot follow up the incident they attended.
    ('patrol', 'rms.anmalan.view'),
    ('patrol', 'rms.anmalan.create'),

    -- Brottskatalogen (spec 7.10). Reading it is patrol work by necessity
    -- rather than by rank: an officer who cannot list the offences cannot
    -- write a charge, so the charging screen would be empty for everyone who
    -- actually attends incidents. The catalogue carries no personal data --
    -- it is the statute -- so there is nothing here that a lower rank should
    -- not see.
    ('patrol', 'rms.brott.view'),

    -- Approving an anmälan, and editing somebody else's draft. Supervisor
    -- grants, because both are oversight rather than work.
    --
    -- `rms.anmalan.approve` does **not** let its holder approve their own
    -- anmälan. That rule lives in `Anmalan.canApprove` and no permission
    -- reaches it, deliberately: the whole value of an approval step is that a
    -- second person looked, and on a small server the supervisor is also the
    -- author of half the reports. A grant that let the check be skipped is a
    -- grant that would be given to the one person who most wanted it.
    ('supervisor', 'rms.anmalan.approve'),
    ('supervisor', 'rms.anmalan.edit.any'),

    -- Förundersökningen (spec 7.8). Opening and leading an investigation is
    -- investigator work; `inv.fu.assign` is the supervisor half, and it is what
    -- lets a stalled investigation be reassigned when its ledare has left --
    -- otherwise unreachable, because every decision belongs to the ledare.
    ('patrol', 'inv.fu.view'),
    ('supervisor', 'inv.fu.open'),
    ('supervisor', 'inv.fu.lead'),
    ('command', 'inv.fu.assign'),

    -- Frihetsberövande (spec 7.9). The three decisions of RB, and they are the
    -- one place in FredPD where a permission stands for a **legal capacity**
    -- rather than for a job in the department.
    --
    -- `frihet.gripande` is patrol work: an officer may seize somebody caught in
    -- the act (RB 24:7), and that decision is theirs and provisional.
    --
    -- `frihet.anhallande` is the **åklagare's** (RB 24:6) and
    -- `frihet.haktning` is the **tingsrätt's** (RB 24:13). Neither is seeded to
    -- any police group, and that is the whole point of the separation: an
    -- officer who could anhålla would be taking the decision the prosecutor
    -- exists to take. They are seeded to their own groups, which a server maps
    -- its DOJ Discord roles onto.
    --
    -- `frihet.frigiv` goes to everybody, including plain patrol. A
    -- frihetsberövande that should end must be able to end at once -- most
    -- commonly because the prosecutor did not anhålla -- and making release
    -- wait for the right rank to be online would hold people for the
    -- convenience of the permission model.
    ('patrol', 'frihet.view'),
    ('patrol', 'frihet.gripande'),
    ('patrol', 'frihet.frigiv'),
    ('aklagare', 'frihet.view'),
    ('aklagare', 'frihet.anhallande'),
    ('aklagare', 'frihet.frigiv'),
    ('domare', 'frihet.view'),
    ('domare', 'frihet.haktning'),
    ('domare', 'frihet.frigiv'),

    -- Standing in (spec 7.9.1). Not the capacity itself: a stand-in grant
    -- takes a decision only while nobody holding the real one is signed on,
    -- never on a chain its holder arrested or anhöll, and every decision it
    -- takes is marked as a stand-in's on the custody record. A supervisor may
    -- stand in for the åklagare; command, which inherits that, also for the
    -- domare. `frihet.fallback = false` in config/server.lua turns it off.
    ('supervisor', 'frihet.fallback.aklagare'),
    ('command', 'frihet.fallback.domare'),

    -- Tvångsmedel (spec 7.12). Reading them is ordinary work -- an officer
    -- about to force a door has to be able to see what authorises it. Deciding
    -- one is the förundersökningsledare's, which on the police side means a
    -- supervisor; `tvang.decide.aklagare` and `.domare` raise the capacity, and
    -- the capacity is what decides whether a kroppsbesiktning may be ordered.
    --
    -- `tvang.verkstall` is separate from `tvang.decide` on purpose: the officer
    -- who carries a husrannsakan out is not usually the one who decided it, and
    -- a server where those were one grant could not record that they differed.
    ('patrol', 'tvang.view'),
    ('patrol', 'tvang.verkstall'),
    ('supervisor', 'tvang.decide'),
    ('aklagare', 'tvang.view'),
    ('aklagare', 'tvang.decide'),
    ('aklagare', 'tvang.decide.aklagare'),
    ('domare', 'tvang.view'),
    ('domare', 'tvang.decide'),
    ('domare', 'tvang.decide.domare'),

    -- Efterlysning (spec 7.13). Issuing one makes somebody turn up wanted on
    -- every query on the server, so it sits with the prosecutor and with
    -- command rather than with patrol.
    ('command', 'efterlysning.issue'),
    ('aklagare', 'efterlysning.issue'),

    -- Spaningsuppdrag (spec 7.13). Raising one is patrol work, and that is the
    -- difference between this and an efterlysning: an efterlysning is a
    -- prosecutor's decision that somebody be detained, and a spaningsuppdrag is
    -- an officer saying "look for this van". A department where the second
    -- needed command approval would simply not use it, and the sightings would
    -- stay in the radio traffic where nothing can search them.
    --
    -- What patrol cannot do is make a lookout as loud as an efterlysning:
    -- `Spaning.bannerFor` caps it, and no permission reaches that.
    ('patrol', 'spaning.view'),
    ('patrol', 'spaning.create'),

    -- Surveillance (spec 9, M5). The secret, tingsrätt-decided measures --
    -- HAK, HRA, spårsändare, kameraövervakning -- and the one place besides
    -- frihet where a permission stands for a legal capacity rather than a job.
    --
    -- `surv.request` is the åklagare's application; `surv.decide` is the
    -- domare's grant or refusal; `surv.upphav` is either's early revocation
    -- (RB 27:23). None is seeded to a police group, for the same reason
    -- `frihet.anhallande` and `frihet.haktning` are not: an officer who could
    -- request would be taking the decision the prosecutor exists to take.
    --
    -- `surv.view` is broader -- reading the register, and the base gate on
    -- observing once a measure is granted -- and it goes to command and the
    -- source handler as well as to the DOJ groups, because an intelligence
    -- unit built the case that led to the application and reads the result.
    -- `surv.log.view` is narrower again: the observer log names who listened
    -- and when, and stays with command and the DOJ groups only.
    ('aklagare', 'surv.view'),
    ('aklagare', 'surv.request'),
    ('aklagare', 'surv.upphav'),
    ('aklagare', 'surv.log.view'),
    ('aklagare', 'page.surveillance'),
    ('domare', 'surv.view'),
    ('domare', 'surv.decide'),
    ('domare', 'surv.upphav'),
    ('domare', 'surv.log.view'),
    ('domare', 'page.surveillance'),
    ('command', 'surv.view'),
    ('command', 'surv.log.view'),
    ('command', 'page.surveillance'),

    -- The per-method capability to actually observe once a measure is live
    -- (`hak.session.start`, `hak.intercept.add`). Held by the source handler,
    -- not by ordinary intelligence work: `intel_analyst` reads and writes the
    -- register, and listening to a live interception is a further step up
    -- from that, matching `intel_handler`'s own "may also see where protected
    -- intelligence came from".
    ('intel_handler', 'surv.view'),
    ('intel_handler', 'surv.phone.intercept'),
    ('intel_handler', 'surv.radio.monitor'),
    ('intel_handler', 'surv.device.deploy'),
    ('intel_handler', 'surv.device.listen'),
    ('intel_handler', 'surv.tracker.deploy'),
    ('intel_handler', 'surv.tracker.view'),
    ('intel_handler', 'page.surveillance'),

    -- Åtal och dom (spec 7.20). The charging decision is the åklagare's
    -- alone -- `court.referral.review` -- and only a domare may enter a
    -- disposition -- `court.disposition.enter`. Neither inherits the other,
    -- the same separation `frihet.anhallande` and `frihet.haktning` keep,
    -- and for the identical reason: a prosecutor who could also sentence
    -- their own charge is a prosecutor who is also the court.
    ('aklagare', 'court.referral.review'),
    ('aklagare', 'page.court'),
    ('domare', 'court.disposition.enter'),
    -- A domare has to see the docket to pick a case to dispose of, and the
    -- referral decision itself (which charges, on what ground) is exactly
    -- what a sentence has to be read against.
    ('domare', 'court.referral.review'),
    ('domare', 'page.court'),
    ('command', 'page.court'),

    -- Reading the catalogue and the two registers the prosecutor's and the
    -- court's own forms pick from: charges are chosen from the brottskatalog
    -- (ChargePicker), and a measure or a wanted notice names a person or a
    -- vehicle by searching for it (PersonPicker, VehiclePicker). Without
    -- these the forms could not be filled in at all by the people they are
    -- for. Read-only; searches are logged like everyone else's (7.2).
    ('aklagare', 'rms.brott.view'),
    ('aklagare', 'rms.person.view'),
    ('aklagare', 'rms.vehicle.view'),
    ('domare', 'rms.brott.view'),
    ('domare', 'rms.person.view'),
    ('domare', 'rms.vehicle.view'),

    -- The two field-level grants of spec 4.5. Without a group holding them the
    -- fields are not protected, they are invisible: the routes read the
    -- permission on every path that returns the field, so a department that
    -- granted nobody them would simply never see a victim's address or know a
    -- mental-health caution exists.
    --
    -- An address is ordinary supervisory work. A mental-health caution is not:
    -- an officer who cannot be told the detail cannot act on it either way, so
    -- it is held where the decision to look is a deliberate one.
    ('supervisor', 'fields.victim_address.view'),
    ('command', 'fields.mental_health.view'),

    -- A firearm trace reaches into the ballistic index and says which weapon
    -- fired what. Command only, matching `evidence.item.release` above it.
    ('command', 'rms.firearm.trace'),

    -- A supervisor sees the whole department's traffic, not just their agency's.
    ('supervisor', 'comms.pdchat.all'),

    -- Command staff read the audit log.
    ('command', 'admin.audit.view'),
    ('command', 'page.personnel'),

    -- -------------------------------------------------------------------------
    -- Dispatch, the map and ALPR (spec 7.16-7.18, M4)
    --
    -- Two audiences, not one. A dispatcher works the console; an officer works
    -- the same calls from the car. Everything the officer does there -- take a
    -- call, report progress, press the button, clear with a disposition -- is
    -- granted to `patrol` below and not to `dispatch`, because M4's acceptance
    -- criterion is a P1 run end to end and a P1 only a dispatcher can touch
    -- never leaves the console. Appendix F is the same split written as a
    -- command line: `ATT`, `ST` and `CLR` are typed by the officer.
    -- -------------------------------------------------------------------------

    -- Reading dispatch is reading. The pending queue, a call card, the unit
    -- board, the live map and the broadcast board are gated on `page.dispatch`
    -- and on nothing else, which is why it sits here rather than at `dispatch`:
    -- an officer who cannot see the queue has nothing to self-assign to, and
    -- 4.4 says the page declares what it needs and the routes enforce the same
    -- rule -- so the rail key and the read key are one key, not two.
    ('patrol_basic', 'page.dispatch'),

    -- The panic button and the officer's own status, at the lowest group there
    -- is. Both move the presser's own row and nothing else: `cad.unit.status`
    -- sets your unit's status and reports your progress on a call,
    -- `cad.emergency` raises the P1 at the position the server reads off your
    -- ped. Neither names another officer, so neither can be turned on somebody
    -- else (invariant 1).
    --
    -- This is the one place the "a trainee changes no record" line above is
    -- crossed, deliberately: an emergency call is a record, and the aspirant in
    -- the passenger seat is the person with the least experience and the most
    -- reason to press it. A panic button a trainee cannot press is a panic
    -- button that fails the only shift it was needed on.
    --
    -- `dispatch` used to inherit both and could use neither, and that inherited
    -- `cad.unit.status` is why `cad/events.lua` needed a negative marker to keep
    -- console operators off the unit board. `dispatch` inherits nothing now, so
    -- these two stop at the officer groups and the board test is a plain "holds
    -- `cad.unit.status`" -- which is also what makes this the key to think
    -- twice about granting to a non-patrol group: whoever holds it and goes on
    -- duty is a car a dispatcher can send to a robbery.
    ('patrol_basic', 'cad.unit.status'),
    ('patrol_basic', 'cad.emergency'),

    -- Patrol works calls. Self-assignment is 7.16's own word for it, clearing
    -- with a disposition is `CLR` in Appendix F, and the narrative log is where
    -- what actually happened gets written -- an officer who can attend a call
    -- but not add a line to it leaves dispatch typing up the radio by hand.
    --
    -- `cad.call.link` is held apart from `cad.call.note` because linking
    -- reaches into the registers: the handler runs the same access check
    -- `rms.person.view` would (invariant 4), and a department that wants field
    -- units narrating calls without touching the master name index can say so.
    ('patrol', 'cad.call.self_assign'),
    -- Raising your own call from the field -- a traffic stop, something seen
    -- on patrol -- without the console (7.16, `call.self_initiate`).
    ('patrol', 'cad.call.self_initiate'),
    ('patrol', 'cad.call.clear'),
    ('patrol', 'cad.call.note'),
    ('patrol', 'cad.call.link'),

    -- Plate reads (7.18). An officer whose car raised a hotlist banner has to
    -- be able to open the read behind it, or the banner is a reason to stop a
    -- car that nobody can account for afterwards. Reading the file is logged
    -- like any other query, and 11.4 is why the reads are swept at 30 days.
    ('patrol', 'alpr.read.view'),

    -- A field supervisor (Appendix A) manages units and puts out a lookout from
    -- the car, which is why neither key is pinned to the console in the
    -- schemas. `cad.unit.manage` is also the key the handler
    -- reads for 7.16's supervisor acknowledgement: an emergency call cannot be
    -- cleared without one, and the people who hold this key -- supervisor,
    -- command, dispatch -- are exactly the people who may give it. A separate
    -- `cad.emergency.ack` key would have been a fifth CAD permission that
    -- answers the same question this one already answers.
    ('supervisor', 'cad.unit.manage'),
    ('supervisor', 'cad.broadcast'),

    -- Putting a plate on the hotlist is putting a red banner in front of an
    -- officer about to stop a car, so it sits a rank up from reading one.
    ('supervisor', 'alpr.hotlist.manage'),

    -- The dispatcher. `dispatch` inherits nothing (see the group row above), so
    -- everything it holds is written out here -- starting with the four keys it
    -- used to pick up from `patrol_basic` and genuinely needs: the MDT rail
    -- entries for records and comms, and the internal channel it runs the shift
    -- on. `page.dispatch` was granted here even when it was inherited, and the
    -- reason still stands: the console is this group's whole job and it must not
    -- stop working because somebody edits an inheritance edge.
    ('dispatch', 'page.records'),
    ('dispatch', 'page.comms'),
    ('dispatch', 'comms.pdchat.send'),
    ('dispatch', 'comms.pdchat.view'),

    -- `cad.console.open` WAS HERE AND IS RETIRED. The comment that stood in its
    -- place said it was "what the dispatch console placement calls", and that
    -- described a mechanism that has never existed: a placement carries no
    -- permission at all (ADR-006, `core/placements.lua`), and the two
    -- create-and-assign routes are pinned to the placement by `accessPoint` and
    -- gated on `cad.call.create` and `cad.call.dispatch`, which are right here.
    -- Nothing read the key as a grant anywhere in the product. Its only effect
    -- was in `cad/events.lua`, which disqualified whoever held it from the unit
    -- board -- so an administrator who granted it to `supervisor` off the
    -- strength of this comment signed every field supervisor off the board and
    -- killed their panic button, and the console they were trying to open had
    -- never needed a key.
    --
    -- Dropping a grant from a seed is safe where dropping a migration is not:
    -- this file is re-runnable upserts (see the header), not schema history. A
    -- database that already ran the old seed keeps its row, because the
    -- statement this comment sits inside is an INSERT IGNORE and nothing here
    -- deletes; that row is inert, since nothing asks for the key any more. The
    -- same treatment `forensics.trace.report` got under ADR-013, for the same
    -- reason. The key is also out of Appendix B and out of the admin catalogue
    -- in `modules/admin/routes.lua`, which is what stops the group editor
    -- offering it again.
    --
    -- `cad.call.self_assign` is absent for the reason that has not changed: a
    -- dispatcher is not a unit, has no `fpd_units` row and has nowhere to be
    -- dispatched to.
    ('dispatch', 'page.dispatch'),
    ('dispatch', 'cad.call.create'),
    ('dispatch', 'cad.call.dispatch'),
    ('dispatch', 'cad.call.clear'),
    ('dispatch', 'cad.call.note'),
    ('dispatch', 'cad.call.link'),
    ('dispatch', 'cad.unit.manage'),
    ('dispatch', 'cad.broadcast'),

    -- Dispatch does not inherit `patrol`, so the two ALPR keys are granted
    -- again rather than picked up: a dispatcher checks a read against a call
    -- and is usually the person who puts a stolen plate on the list in the
    -- first place.
    ('dispatch', 'alpr.read.view'),
    ('dispatch', 'alpr.hotlist.manage'),

    -- The register reads, granted again for the same reason and for a sharper
    -- one: WITHOUT THESE TWO ROWS `cad.call.link` ABOVE IS A KEY WITH NOTHING
    -- BEHIND IT. `call.link` takes a register row id and refuses a name or a
    -- plate deliberately (7.16), so the only way to obtain one is
    -- `person.search` or `vehicle.search` -- and those are gated on these keys.
    -- A dispatcher granted `cad.call.link` and not these pressed Search on the
    -- call card, was answered `forbidden`, and could never reach the route the
    -- seed had just given them. The comment above `('patrol', 'cad.call.link')`
    -- says linking "reaches into the registers: the handler runs the same
    -- access check `rms.person.view` would"; this is the other half of that
    -- sentence written down, because a group that may link has to be able to
    -- read what it is linking.
    --
    -- `page.records` is already here through `patrol_basic`, so the rail has
    -- been opening the register for dispatchers all along and every search on
    -- it refused. These rows make the page do what the rail already advertised.
    --
    -- What they unlock is four read routes and nothing else: `person.search`,
    -- `person.get`, `vehicle.search`, `vehicle.get`. Running names and plates
    -- is the canonical dispatcher job, and every other control still applies
    -- unchanged -- `dispatch` holds `clearance.internal` and nothing above it,
    -- so a restricted record still comes back as the 4.5 stub, and the two
    -- field grants are somebody else's: `fields.victim_address.view` is
    -- `supervisor`'s and `fields.mental_health.view` is `command`'s.
    --
    -- What is deliberately NOT here: every `rms.*.edit` and `rms.vehicle.flag`
    -- (a dispatcher reads the register, they do not correct it);
    -- `rms.firearm.view`, because nothing a dispatcher does reaches the weapons
    -- register and a link is only ever to a person or a vehicle
    -- (`Repo.linkTarget` knows those two kinds and no other); and the unified
    -- query keys `query.run`, `query.person.run`, `query.vehicle.run` and
    -- `query.hit.confirm`, which stay with `patrol` -- opening a record is not
    -- the same act as running a 7.2 query, and confirming a hot-file hit is a
    -- decision for the officer standing at the car.
    ('dispatch', 'rms.person.view'),
    ('dispatch', 'rms.vehicle.view'),

    -- -------------------------------------------------------------------------
    -- Record clearance (spec 4.5, Appendix B and C)
    -- -------------------------------------------------------------------------

    -- WITHOUT THESE ROWS THE PRODUCT DOES NOT WORK AT ALL, and it fails in the
    -- least obvious way there is. `Access.clearanceOf` answers `open` for a
    -- session holding no `clearance.*` key; every record table defaults its
    -- `classification` column to `internal`; and the read rule is clearance >=
    -- classification. So on a freshly seeded server every person, vehicle,
    -- firearm and call was refused to everybody, including the officer who had
    -- just created it -- a blank screen with no error, because a refused read is
    -- deliberately indistinguishable from nothing to show (4.5).
    --
    -- `internal` is the ordinary working level: it is what an unclassified
    -- record is, so being cleared to it means "may do the job", not "is
    -- trusted with something". The levels above it are the ladder, and they
    -- follow supervision rather than seniority -- a source handler outranks a
    -- patrol supervisor here because of what they read, not where they sit.
    --
    -- Granted per group rather than to one base group everyone inherits,
    -- because half of these do not inherit from `patrol_basic` at all
    -- (`dispatch` does; `evidence_tech`, `lab_analyst`, `property_officer` and
    -- the intelligence groups are roots).
    ('patrol_basic', 'clearance.internal'),
    ('supervisor', 'clearance.restricted'),
    ('command', 'clearance.confidential'),
    ('dispatch', 'clearance.internal'),

    ('evidence_tech', 'clearance.internal'),
    ('property_officer', 'clearance.internal'),
    ('lab_analyst', 'clearance.internal'),
    ('lab_supervisor', 'clearance.restricted'),
    ('utredare', 'clearance.internal'),

    -- Intelligence reads what the rest of the department may not (spec 10), so
    -- it starts a rung higher and its command tier is the only group seeded at
    -- `secret`.
    ('intel_analyst', 'clearance.restricted'),
    ('intel_handler', 'clearance.confidential'),
    ('intel_command', 'clearance.secret'),

    -- Administration configures the system: permissions, placements, fleet.
    -- Note what is absent: no record clearance, no compartments. An admin who
    -- needs to read records is granted a records group as well, deliberately
    -- and visibly (spec 4.3, Appendix C).
    ('admin', 'page.admin'),
    ('admin', 'admin.permissions.edit'),

    -- Editing the groups themselves, not just which role gets which group.
    -- Held apart from `admin.permissions.edit` on purpose: mapping a role to an
    -- existing bundle and authoring what a bundle is worth are different
    -- powers, and a server that wants one without the other must be able to
    -- say so.
    ('admin', 'admin.groups.edit'),

    ('admin', 'admin.placement.edit'),
    ('admin', 'admin.branding.edit'),
    ('admin', 'admin.audit.view'),
    ('admin', 'garage.fleet.edit'),

    -- Editing brottskatalogen (spec 7.10). `admin` and nobody else, including
    -- not `command`: a straffskala is the legal basis every charge on every
    -- record is measured against, and an edit to one is quoted in court long
    -- after whoever made it has forgotten. The routes behind it are `sensitive`
    -- too, so a stale Discord snapshot cannot be used to reach them (4.2).
    --
    -- Editing is additive by construction -- a change writes a new version and
    -- supersedes the old one, it never rewrites a row a record cites (7.10) --
    -- so the power this grants is to change what can be charged *next*, not to
    -- alter what was charged before. That is why it is a grant at all rather
    -- than something reserved to a migration.
    ('admin', 'admin.brott.edit'),

    -- The health screen (7.30). It goes to `admin` and to nobody else, because
    -- it is the one group whose job is the running system rather than the
    -- records in it -- and because what the screen shows is totals about the
    -- server, not anything about a case: counts of sessions, how old the
    -- Discord snapshot is, and the forensics grid's counters.
    --
    -- It is granted here rather than left in the catalogue for somebody to add
    -- because the route is unreachable without a grant, and `admin.health` is
    -- what ADR-013 leans on: the public tier writes no audit row for a trace a
    -- criminal destroys, and the grid's `destroyed` counter is the only mark
    -- the act leaves anywhere. A counter behind a permission no group holds is
    -- the same as no counter at all.
    ('admin', 'admin.health.view'),

    -- The crime scene technician (8.4). Collecting is a specialist job: a
    -- patrol officer who picks a casing up off the ground has not collected
    -- evidence, they have contaminated a scene.
    --
    -- `forensics.evidence.collect` gates one route, `evidence.collect`, which
    -- is the only route that writes an evidence item. It covers both ways of
    -- securing a sample: a `traceKey` takes a trace out of the grid, and a
    -- `targetId` takes residue off a person's hands (8.2). They are the same
    -- act -- a technician securing a sample -- so they are the same grant, and
    -- there is no separate swab key: it would be a fifth forensics permission
    -- the spec does not have (Appendix B lists four) and a group nobody
    -- remembered to give it to, which is how a route ships dead.
    ('evidence_tech', 'page.evidence'),
    ('evidence_tech', 'forensics.scene.create'),
    ('evidence_tech', 'forensics.scene.release'),
    ('evidence_tech', 'forensics.evidence.collect'),
    ('evidence_tech', 'forensics.tools.use'),
    ('evidence_tech', 'evidence.item.view'),
    -- The live scanner (8.8): a separate grant from `forensics.evidence.collect`
    -- because it discloses a detained person's identity rather than collecting
    -- a sample, the same reasoning that keeps property intake and disposal
    -- apart below.
    ('evidence_tech', 'forensics.identity.scan'),

    -- The property room (8.6). Note what is separate: intake and disposal are
    -- not the same grant, because destroying evidence should be a decision
    -- somebody is named for.
    ('property_officer', 'page.evidence'),
    ('property_officer', 'evidence.item.view'),
    ('property_officer', 'evidence.item.intake'),
    ('property_officer', 'evidence.item.transfer'),
    ('property_officer', 'evidence.item.checkout'),
    ('property_officer', 'evidence.item.reseal'),
    ('property_officer', 'evidence.audit.run'),

    -- The lab (8.7).
    ('lab_analyst', 'page.lab'),
    ('lab_analyst', 'evidence.item.view'),
    ('lab_analyst', 'lab.request.create'),
    ('lab_analyst', 'lab.queue.view'),
    ('lab_analyst', 'lab.analysis.perform'),

    -- An investigator, same three lab grants as an analyst, held without the
    -- separate role (see the group definition above).
    ('utredare', 'page.lab'),
    ('utredare', 'evidence.item.view'),
    ('utredare', 'lab.request.create'),
    ('utredare', 'lab.queue.view'),
    ('utredare', 'lab.analysis.perform'),

    -- Technical review by a second analyst before release (8.7). Held apart
    -- from performing the analysis on purpose: reviewing your own work is not
    -- a review.
    ('lab_supervisor', 'lab.analysis.review'),
    ('lab_supervisor', 'lab.report.release'),

    -- Command signs off on releasing and disposing of evidence.
    ('command', 'evidence.item.view'),
    ('command', 'evidence.item.release'),
    ('command', 'evidence.item.dispose'),

    -- The analyst: the whole register, read and write.
    ('intel_analyst', 'page.intel'),
    ('intel_analyst', 'intel.module.open'),
    ('intel_analyst', 'intel.person.view'),
    ('intel_analyst', 'intel.person.edit'),
    ('intel_analyst', 'intel.org.view'),
    ('intel_analyst', 'intel.org.edit'),
    ('intel_analyst', 'intel.case.view'),
    ('intel_analyst', 'intel.case.edit'),
    ('intel_analyst', 'intel.report.view'),
    ('intel_analyst', 'intel.report.create'),
    ('intel_analyst', 'intel.report.edit'),
    ('intel_analyst', 'intel.evidence.add'),

    -- The handler. `intel.source.view` is the one that matters: without it a
    -- note from an informant, a wiretap or surveillance is readable but its
    -- source is withheld. That distinction is the whole reason the group
    -- exists -- in PD-Span every account could see every source.
    ('intel_handler', 'intel.source.view'),
    ('intel_handler', 'intel.person.merge'),

    -- Command. Deletion is separated deliberately: intelligence is meant to
    -- outlive the record it hung on, and destroying it should be a decision
    -- somebody is named for.
    ('intel_command', 'intel.record.delete');

-- -----------------------------------------------------------------------------
-- Personnel (spec 7.22-7.24, M6)
--
-- Every officer opens their own roster entry and clocks their own shift --
-- `personnel.shift.own` never takes an id, so granting it widely grants
-- nothing beyond the presser's own row (spec 7.22's own reasoning, the same
-- shape `cad.unit.status` already uses for the panic button). Editing
-- somebody else's roster row, assigning equipment and issuing certifications
-- are supervisory. The disciplinary file is IA-classified and ships stubbed
-- to everyone until an operator configures `internal_affairs` (spec 4.5), so
-- granting `personnel.discipline.view` here only decides who is *asked* --
-- the compartment decides who is *shown*.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol_basic', 'page.personnel'),
    ('patrol_basic', 'personnel.roster.view'),
    ('patrol_basic', 'personnel.shift.own'),

    ('supervisor', 'personnel.roster.edit'),
    ('supervisor', 'personnel.equipment.manage'),
    ('supervisor', 'personnel.certification.manage'),

    ('command', 'personnel.discipline.view'),
    ('command', 'personnel.discipline.manage');

-- -----------------------------------------------------------------------------
-- Booking (spec 7.9, M6)
--
-- Custodial administration, not a legal decision -- the same tier split
-- `frihet` uses for `gripande`/`frigiv`: visibility for everyone including a
-- trainee (`page.booking`, `booking.view` at `patrol_basic`), intake and
-- release for an ordinary officer (`booking.intake`, `booking.release` at
-- `patrol`). Neither `aklagare` nor `domare` gets anything here.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol_basic', 'page.booking'),
    ('patrol_basic', 'booking.view'),

    ('patrol', 'booking.intake'),
    ('patrol', 'booking.release');

-- -----------------------------------------------------------------------------
-- Vehicle impound (spec 7.15, M6)
--
-- Viewing and creating an impound is ordinary patrol work -- an officer who
-- tows a car writes the record for it, the same reasoning `rms.anmalan.create`
-- gets. Authorizing an investigative or evidence hold is the investigator-tier
-- decision spec 7.15 calls out by name; it sits with `inv.fu.lead` at
-- `supervisor` rather than with `inv.fu.assign` at `command`, because it is the
-- same "leads the investigation" capacity that already opens and leads an FU,
-- not the narrower reassignment power `command` alone holds. Release is
-- patrol work again: `Impound.mayRelease` is the real gate (fee paid, and
-- authorized when the hold needs it), so nothing is gained by also
-- restricting who may press the button once those conditions are met.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol_basic', 'page.impound'),
    ('patrol', 'impound.view'),
    ('patrol', 'impound.create'),
    ('patrol', 'impound.release'),
    ('supervisor', 'impound.authorize');

-- -----------------------------------------------------------------------------
-- Ordningsbot (spec 7.11, M6)
--
-- The fine schedule and citation history are visible department-wide, the
-- same tier `booking.view` gets. Issuing, marking a citation contested (intake
-- paperwork, not a disposition -- the disposition is `court.disposition.enter`
-- if it goes to court) and marking one paid (no billing bridge exists yet; see
-- 0019's header) are full-duty work at `patrol`, so the officer who wrote the
-- ticket is never stranded from its own follow-up. Voiding an already-issued
-- citation is a correction, held at `supervisor` the same way
-- `impound.authorize` holds a reversal above the tier that first acted.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol_basic', 'page.ordningsbot'),
    ('patrol_basic', 'ordningsbot.tariff.view'),
    ('patrol_basic', 'ordningsbot.view'),

    ('patrol', 'ordningsbot.issue'),
    ('patrol', 'ordningsbot.contest'),
    ('patrol', 'ordningsbot.pay'),

    ('supervisor', 'ordningsbot.void');

-- -----------------------------------------------------------------------------
-- Locations and premises (spec 7.6)
--
-- Reading the address index is ordinary work for anybody who answers a call,
-- dispatchers included: the hazard on a premise is for the person about to
-- knock on its door. Registering an address, linking its keyholders and
-- flagging a hazard is patrol work -- the officer who met the dog is the one
-- who knows about it.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol_basic', 'rms.location.view'),
    -- `dispatch` is a root group (it does not inherit patrol_basic), and the
    -- hazard on a call card is first read at the console.
    ('dispatch', 'rms.location.view'),
    ('patrol', 'rms.location.edit'),
    ('patrol', 'rms.location.hazard.edit');

-- -----------------------------------------------------------------------------
-- Field interviews and stop data (spec 7.14)
--
-- Writing a card or recording a stop is patrol work, and so is reading the
-- cards -- a card is written to be found by the next officer who meets the
-- same person. The stop list names no person, and a plate only to a reader
-- of that vehicle, so it is ordinary reading too.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol', 'rms.fi.create'),
    ('patrol', 'rms.fi.view'),
    ('patrol', 'rms.stops.create'),
    ('patrol', 'rms.stops.view');

-- -----------------------------------------------------------------------------
-- The ordningsbot tariff editor (spec 7.11, 0036)
--
-- What a fine costs and what it does to a licence is the agency's policy,
-- set by its command -- the same level that already owns the offence
-- catalogue beside it.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('command', 'ordningsbot.tariff.edit');

-- -----------------------------------------------------------------------------
-- Photographs on a person's record (spec 7.3, ADR-019)
--
-- A field photograph, a scar, a tattoo: the officer who met the person takes
-- it. A mugshot is the booking terminal's and rides on `booking.intake`,
-- which patrol already holds.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol', 'rms.person.photo.upload');

-- -----------------------------------------------------------------------------
-- Printing (spec 7.28, ADR-020)
--
-- Printing a copy of a record an officer may already read: the citation handed
-- to a driver, the custody log for the file. The record's own read permission
-- is asked again by the module that prints it.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol_basic', 'document.print');

-- A PDF of a restricted, compartmented or sealed record is an export (spec
-- 11.1, ADR-020 amended): the link is a bearer link, and the file outlives
-- the session that made it. Supervisors and investigators, not all of patrol.
INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('supervisor', 'document.export.restricted'),
    ('utredare', 'document.export.restricted');

-- -----------------------------------------------------------------------------
-- Discord role actions (ADR-022)
--
-- Hiring and dismissing (the hire role) and promoting and demoting (a rank)
-- as a Discord role change. Command only: a role granted is never worth more
-- than the granter holds, and nobody changes their own.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('command', 'personnel.hire'),
    ('command', 'personnel.promote');

-- -----------------------------------------------------------------------------
-- Reports from the public (spec 7.29, 0040)
--
-- A stolen-property report handed in at a front desk is read and closed by
-- patrol. A complaint about the police is read by internal affairs alone
-- (`ia.case.view` / `ia.case.manage`). `public.report.view` is the door to
-- the inbox and the kind decides what is behind it, so an operator who sets
-- up internal affairs grants that group `public.report.view` as well (the
-- seed configures no internal-affairs group; see the installation guide).
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol', 'public.report.view'),
    ('patrol', 'public.report.handle');
