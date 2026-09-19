-- 0002_brott.sql — the starter brottskatalog (spec 7.10).
--
-- Seeds ship with the product and must be re-runnable without duplicating
-- rows, so this is an INSERT IGNORE against `uq_fpd_brott_version`.
--
--
-- WHAT THIS IS, AND WHAT IT IS NOT
--
-- A working starting point: the offences an RP police department actually
-- charges, with the straffskala each one carries in Swedish law as it stands.
-- It is not the whole of brottsbalken, and it is not legal advice. An
-- administrator adds, versions and retires entries from the MDT under
-- `admin.brott.edit`, and 7.10's versioning rule means doing so never alters
-- a record already written against an earlier version.
--
-- **Every row is seeded for every agency**, by joining `fpd_agencies` rather
-- than naming one. A catalogue is per agency (`fpd_brott.agency_id`) because
-- a server may run departments in different jurisdictions, but the statute is
-- the same statute -- so each agency starts from the same rows and diverges
-- only if somebody edits one.
--
-- Version 1 throughout, and `superseded_at` NULL, so every row is current.
-- `created_by` is NULL: nobody authored these, the seed did.
--
--
-- ABOUT THE NUMBERS
--
-- The three penalty columns are months, and they are read together (see 0008):
--
--   boter = 1, max = 0      böter only, no fängelse at all (olovlig körning)
--   boter = 1, max = 6      "böter eller fängelse i högst sex månader"
--   boter = 0, min = 0      "fängelse i högst N"
--   boter = 0, min > 0      "fängelse i lägst M och högst N"
--   max = NULL              livstid (mord)
--
-- `preskription_years` follows BrB 35:1 from the ceiling, and is NULL for the
-- two offences BrB 35:2 exempts -- mord and dråp have not been subject to
-- preskription since 2010. It is stored rather than derived because those
-- exceptions exist: a formula would quietly give mord a twenty-five year
-- limitation period that the law removed.
--
-- `forsok` and `forberedelse` say whether attempt and preparation are
-- punishable for this offence (BrB 23). They are not a property of the
-- straffskala; they are separate statements in each kapitel, so they are
-- recorded per row rather than inferred from the ceiling.
--
-- Rubriker are locale keys (`brott.rubrik.<slug>`), never literal text
-- (invariant 6, and 5.3 for code tables). Both locale files carry every key
-- this file references, and `pnpm i18n:check` fails if one goes missing.

INSERT IGNORE INTO `fpd_brott`
    (`agency_id`, `code`, `version`, `balk`, `kapitel`, `paragraf`, `stycke`,
     `label_key`, `grad`, `boter`,
     `fangelse_min_months`, `fangelse_max_months`,
     `forsok`, `forberedelse`, `preskription_years`)
SELECT
        a.`id`, t.`code`, t.`version`, t.`balk`, t.`kapitel`, t.`paragraf`, t.`stycke`,
        t.`label_key`, t.`grad`, t.`boter`,
        t.`fangelse_min_months`, t.`fangelse_max_months`,
        t.`forsok`, t.`forberedelse`, t.`preskription_years`
    FROM `fpd_agencies` a
    CROSS JOIN (
        SELECT 'BRB-3-1' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               3 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.mord' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               120 AS `fangelse_min_months`, NULL AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, NULL AS `preskription_years`
        UNION ALL
        SELECT 'BRB-3-2' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               3 AS `kapitel`, 2 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.drap' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               72 AS `fangelse_min_months`, 120 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, NULL AS `preskription_years`
        UNION ALL
        SELECT 'BRB-3-5' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               3 AS `kapitel`, 5 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.misshandel' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-3-5-R' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               3 AS `kapitel`, 5 AS `paragraf`, 2 AS `stycke`,
               'brott.rubrik.ringa_misshandel' AS `label_key`, 'ringa' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 6 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-3-6' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               3 AS `kapitel`, 6 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.grov_misshandel' AS `label_key`, 'grov' AS `grad`, 0 AS `boter`,
               18 AS `fangelse_min_months`, 72 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 10 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-4-4' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               4 AS `kapitel`, 4 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.olaga_tvang' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-4-5' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               4 AS `kapitel`, 5 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.olaga_hot' AS `label_key`, 'normal' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 12 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-8-1' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               8 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.stold' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-8-2' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               8 AS `kapitel`, 2 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.ringa_stold' AS `label_key`, 'ringa' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 6 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-8-4' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               8 AS `kapitel`, 4 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.grov_stold' AS `label_key`, 'grov' AS `grad`, 0 AS `boter`,
               6 AS `fangelse_min_months`, 72 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 10 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-8-5' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               8 AS `kapitel`, 5 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.ran' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               12 AS `fangelse_min_months`, 72 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 10 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-8-6' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               8 AS `kapitel`, 6 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.grovt_ran' AS `label_key`, 'grov' AS `grad`, 0 AS `boter`,
               60 AS `fangelse_min_months`, 120 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 15 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-9-1' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               9 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.bedrageri' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-12-1' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               12 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.skadegorelse' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-17-1' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               17 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.vald_mot_tjansteman' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-17-1-R' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               17 AS `kapitel`, 1 AS `paragraf`, 3 AS `stycke`,
               'brott.rubrik.ringa_vald_mot_tjansteman' AS `label_key`, 'ringa' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 6 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-17-4' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               17 AS `kapitel`, 4 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.valdsamt_motstand' AS `label_key`, 'normal' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 6 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'NSL-1' AS `code`, 1 AS `version`, 'NSL' AS `balk`,
               1 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.narkotikabrott' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 36 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 10 AS `preskription_years`
        UNION ALL
        SELECT 'NSL-2' AS `code`, 1 AS `version`, 'NSL' AS `balk`,
               1 AS `kapitel`, 2 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.ringa_narkotikabrott' AS `label_key`, 'ringa' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 6 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'NSL-3' AS `code`, 1 AS `version`, 'NSL' AS `balk`,
               1 AS `kapitel`, 3 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.grovt_narkotikabrott' AS `label_key`, 'grov' AS `grad`, 0 AS `boter`,
               24 AS `fangelse_min_months`, 84 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 10 AS `preskription_years`
        UNION ALL
        SELECT 'TBL-3' AS `code`, 1 AS `version`, 'TBL' AS `balk`,
               1 AS `kapitel`, 3 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.olovlig_korning' AS `label_key`, 'normal' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 0 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'TBL-4' AS `code`, 1 AS `version`, 'TBL' AS `balk`,
               1 AS `kapitel`, 4 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.rattfylleri' AS `label_key`, 'normal' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 6 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'TBL-4A' AS `code`, 1 AS `version`, 'TBL' AS `balk`,
               1 AS `kapitel`, 4 AS `paragraf`, 2 AS `stycke`,
               'brott.rubrik.grovt_rattfylleri' AS `label_key`, 'grov' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'VAPL-9-1' AS `code`, 1 AS `version`, 'VapL' AS `balk`,
               9 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.vapenbrott' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 36 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 10 AS `preskription_years`
        UNION ALL
        SELECT 'VAPL-9-1A' AS `code`, 1 AS `version`, 'VapL' AS `balk`,
               9 AS `kapitel`, 1 AS `paragraf`, 2 AS `stycke`,
               'brott.rubrik.grovt_vapenbrott' AS `label_key`, 'grov' AS `grad`, 0 AS `boter`,
               24 AS `fangelse_min_months`, 60 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 10 AS `preskription_years`
    ) t;
