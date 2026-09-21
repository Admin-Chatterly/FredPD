# vendor/

Third-party and predecessor source kept for reference. **Nothing here is built,
linted, tested or shipped.** The root ESLint config, luacheck and the pnpm
workspace all exclude this directory deliberately.

## pd-span/

PD-Span at commit `1a63203`, imported for the intelligence integration
(spec section 10). It is the existing intelligence board: a Next.js application
on Supabase, **not** a FiveM resource.

Read `docs/pd-span-inventory.md` before working on the `intel` module — it maps
every table to a FredPD entity, lists the permission logic that has to be
replaced, reviews the code against the invariants, and recommends how to
integrate it.

Do not edit anything in here. It is a snapshot of another repository; changes
belong upstream, or in the FredPD code that replaces it.
