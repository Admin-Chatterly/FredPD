-- 0003_fleet_gating.sql
--
-- Fleet gating for the motor pool (spec 7.31): which officers may draw which
-- vehicle, configured from the fleet editor instead of by hand in SQL.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- Until now `fpd_fleet` could restrict a vehicle two ways, both of them
-- permission keys: `permission` (an extra key beyond `garage.vehicle.draw`) and
-- `certification` (7.23, not yet issued to anyone). Neither answers the request
-- a department actually makes, which is "the air unit is the people with the Air
-- Support role in Discord" -- a role that already exists and is already
-- maintained, with no permission group behind it.
--
-- So two more nullable columns, and one rule over both:
--
--   A vehicle is drawable when EITHER the officer holds the Discord role in
--   `required_discord_role`, OR their effective permissions satisfy the
--   permission group in `required_group`, OR both columns are NULL.
--
-- Either gate opens the vehicle. Requiring both would mean every gated vehicle
-- needs two pieces of configuration kept in step, and the first one to drift
-- takes the vehicle away from everyone. The rule lives in one pure function --
-- `FredPD.Modules.garage.gatingSatisfied` -- so it is tested rather than
-- reimplemented per caller, and it is evaluated on the server at draw time
-- (invariant 4). These columns narrow access and never widen it: an officer
-- still needs `garage.vehicle.draw`, still needs to be on duty, and still needs
-- to be standing at the motor pool.
--
-- `ADD COLUMN IF NOT EXISTS` because CI applies every migration twice: the
-- second pass must be a no-op, not error 1060.
--
-- Deliberately no CHECK constraint on either column. There is nothing to check
-- that is not already the application's job -- a role id is a Discord snowflake
-- this database has never seen, and a group key lives in `fpd_permission_groups`
-- whose rows an administrator edits -- and a CHECK here would be the start of
-- the pattern that bit us once already: MariaDB refuses (error 1901) a CHECK
-- that references a column a foreign key sets to NULL, because the delete would
-- then produce a row the CHECK forbids. Both shapes are validated in the route
-- layer, where the officer gets a field error instead of a failed statement.

ALTER TABLE `fpd_fleet`
    -- A permission group key from `fpd_permission_groups`. Deliberately not a
    -- foreign key: a group deleted in the editor must leave the vehicle gated
    -- and undrawable (fail closed), not silently open it to the whole
    -- department the way ON DELETE SET NULL would.
    ADD COLUMN IF NOT EXISTS `required_group` VARCHAR(64) NULL
        COMMENT 'Permission group key; officer must satisfy it. NULL = no group gate'
        AFTER `certification`,

    -- A Discord role id (snowflake). Checked against the role snapshot in
    -- `fpd_discord_members`, which is the only permission source there is
    -- (invariant 2) -- this column just names one role directly instead of
    -- going through a group.
    ADD COLUMN IF NOT EXISTS `required_discord_role` VARCHAR(32) NULL
        COMMENT 'Discord role id; holding it is enough on its own. NULL = no role gate'
        AFTER `required_group`;
