import { readdir, readFile } from 'node:fs/promises';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Checks that what was written is actually reachable (spec 3.5, invariant 3).
 *
 * The other checks in `tools/` prove the code is well formed. This one proves
 * it is connected, which is a different question and the one nothing else in CI
 * can answer: no test here loads a FiveM resource, so a route that is perfectly
 * written, correctly schema'd and fully translated still does nothing if its
 * file is missing from `fxmanifest.lua`. Every failure below has happened.
 *
 * It fails on:
 *
 *   1. a Lua file under a resource that no `fxmanifest.lua` loads — dead code
 *      that looks live, and the reason an entire evidence module once shipped
 *      with only its `service.lua` registered;
 *   2. a route whose `schema` names nothing in `packages/schema`, which is a
 *      crash inside the route wrapper the first time a client calls it;
 *   3. a route the NUI may call that is missing from `NUI_ROUTES` in
 *      `client/main.lua`, so the callback is never registered;
 *   4. a route whose `perm` is granted to no group in the seed, which is a
 *      route nobody can ever reach;
 *   5. a call to `fredpd:<name>` from any resource — the core's client, a
 *      satellite, anything — where no route declares `<name>`. That is how
 *      `forensics.destroy` shipped in ef88b44: `fredpd_forensics` called it
 *      over `lib.callback`, nothing registered it, and every check in CI passed
 *      because nothing in CI loads a resource. 1–4 all start from a route that
 *      exists; only this one starts from the call.
 *   6. a `route.public` handler that reaches for a session, a permission set,
 *      an access check or a repo. ADR-013, spec 3.5.1 and `route.lua` all state
 *      as a flat fact that a public handler cannot touch a record, and all
 *      three attribute it to the signature — the handler is handed a number and
 *      not a session. The signature does not give it: a handler holding a
 *      number can write `FredPD.Core.session.get(src)` and have the session
 *      back. This check is what makes the three claims true, so weakening it
 *      silently falsifies three pieces of prose at once.
 *   7. a route named in `PUBLIC_ROUTES` that is declared with `route.define`.
 *      The assertions in `Route.public` already stop a public route growing a
 *      `perm`; what nothing caught was the other direction, someone converting
 *      one back to `route.define` and adding a permission — which is spec
 *      8.10's named bug, "police-only restrictions must never block criminal
 *      gameplay", reintroduced with a green build.
 *
 * Both route tiers count as declaring a name: `route.define` and, since
 * ADR-013, `route.public`. A public route has no permission by construction, so
 * check 4 simply has nothing to look up for one; everything else applies to it
 * unchanged, and checks 6 and 7 apply to it alone.
 *
 * What it deliberately does not do is guess intent. A route with no NUI
 * callback may be called from Lua; the allowlist below records the ones that
 * are, so adding to it is a decision someone writes down rather than a silent
 * omission.
 */

const here = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(here, '..');
const RESOURCES = join(REPO, 'resources', '[fredpd]');
const SEED = join(REPO, 'database', 'seeds', '0001_permissions.sql');
const SCHEMAS = join(REPO, 'packages', 'schema', 'src', 'schemas.ts');

/**
 * Routes reached from Lua rather than from the NUI, so their absence from
 * `NUI_ROUTES` is correct. Each one needs a reason, because "it is called from
 * somewhere else" is exactly what a forgotten route also looks like.
 */
const SERVER_CALLED: Record<string, string> = {
  'fredpd:close': 'the NUI asks the client to close it; not a route',
  'forensics.observe':
    'a sensor in fredpd_forensics reports it, not the NUI: the satellite calls ' +
    'lib.callback.await on the global event name the core registered (ADR-011)',
  'forensics.process':
    'the powder, luminol and forensic-light tools in fredpd_forensics call it ' +
    'from the world, not from an MDT screen (spec 8.4, ADR-011)',
  'forensics.destroy':
    'ox_target prompts in fredpd_forensics call it — wiping, cleaning, washing ' +
    'and picking up are actions in the world that every player may take, and ' +
    'the MDT is police software (spec 8.10, ADR-013)',
};

/**
 * Routes that MUST be declared with `route.public`, and why (ADR-013's table).
 *
 * These are the two calls spec 8 cannot express any other way: a criminal has
 * no `fpd_officers` row, so no session, so a permissioned route answers
 * `no_session` to exactly the players the feature is for. `Route.public`
 * asserts the opposite direction already — a public route carrying a `perm`
 * does not load — but nothing stopped the conversion back, which is the shape
 * the regression actually takes: `route.public` becomes `route.define`, a
 * plausible `perm` goes on beside it, CI stays green, and half of section 8 is
 * dead on a real server again.
 *
 * Adding to this set is the same decision as adding a public route, and
 * ADR-013 says what that costs: "a third public route is a decision, not a
 * convenience", and it gets an ADR naming the clause that grants it.
 */
const PUBLIC_ROUTES: Record<string, string> = {
  'forensics.observe':
    '8.3.4: the owner of a print is whoever left it, and that is usually not an officer',
  'forensics.destroy':
    '8.10: wiping, cleaning, washing and picking up are available to every player, ' +
    'and "police-only restrictions must never block criminal gameplay"',
};

/**
 * What a `route.public` handler may not name.
 *
 * Every entry is the door into something a public caller does not have. A
 * session carries the agency, the officer id and the permission set; `perms`
 * and `access` answer questions about a reader this tier has not identified;
 * a repo is the records themselves. `FredPD.Core.session.get(src)` is the one
 * that actually compiles and runs today — src is a real server id, and for a
 * player who happens to be an officer it hands back the whole session — which
 * is precisely why the three prose claims need a check under them rather than
 * a signature.
 *
 * The scan is textual and reads only the handler body, so a public handler
 * could still reach a session through a helper defined elsewhere in the file.
 * That is a deliberate floor and not the ceiling: this catches the reflex —
 * someone writing the lookup where they needed it — and the reviewer is still
 * the thing that catches indirection. It is not weakened to accommodate one.
 */
const PUBLIC_HANDLER_FORBIDDEN: readonly { readonly pattern: RegExp; readonly what: string }[] = [
  { pattern: /\bFredPD\.Core\.session\b/, what: 'FredPD.Core.session' },
  { pattern: /\bFredPD\.Core\.perms\b/, what: 'FredPD.Core.perms' },
  { pattern: /\bFredPD\.Core\.access\b/, what: 'FredPD.Core.access' },
  { pattern: /\bFredPD\.Modules\.access\b/, what: 'FredPD.Modules.access' },
  { pattern: /\brepo\b/, what: 'a repo' },
];

/** Files a manifest is allowed not to list. */
const NOT_LOADED = /\/(spec|tests?)\//;

let failures = 0;

function fail(message: string): void {
  console.error(`  - ${message}`);
  failures += 1;
}

async function walk(dir: string): Promise<string[]> {
  const out: string[] = [];

  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);

    if (entry.isDirectory()) {
      if (entry.name === 'node_modules' || entry.name === 'dist') continue;
      out.push(...(await walk(path)));
    } else {
      out.push(path);
    }
  }

  return out;
}

/**
 * Lua line comments, removed before anything else reads the source.
 *
 * Not fussiness: `fxmanifest.lua` carries the comment "never list this in
 * files {}", and a brace inside a comment ended the block early enough to make
 * this check report every server script in the resource as unloaded.
 */
function withoutComments(source: string): string {
  return source.replaceAll(/--\[\[[\s\S]*?\]\]/g, '').replaceAll(/--[^\n]*/g, '');
}

/**
 * The paths one `fxmanifest.lua` loads.
 *
 * Quoted strings inside the script blocks. The blocks are closed by a `}` in
 * the first column, which is how the manifests are written and what lets this
 * stay a scan rather than a Lua parser.
 */
function manifestPaths(source: string): Set<string> {
  const loaded = new Set<string>();

  const blocks = withoutComments(source).matchAll(
    /(?:shared_scripts|server_scripts|client_scripts|files)\s*\{([\s\S]*?)\n\}/g,
  );

  for (const block of blocks) {
    for (const quoted of (block[1] ?? '').matchAll(/'([^']+)'/g)) {
      const path = quoted[1];
      if (path !== undefined) loaded.add(path);
    }
  }

  // `client_script 'file.lua'` and `server_script` singulars.
  for (const single of source.matchAll(/\b(?:client|server|shared)_script\s+'([^']+)'/g)) {
    const path = single[1];
    if (path !== undefined) loaded.add(path);
  }

  return loaded;
}

/** Does any pattern in the manifest cover this path, glob included? */
function isLoaded(path: string, loaded: Set<string>): boolean {
  if (loaded.has(path)) return true;

  for (const pattern of loaded) {
    if (!pattern.includes('*')) continue;

    const expression = new RegExp(
      `^${pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*/g, '.*').replace(/\*/g, '[^/]*')}$`,
    );

    if (expression.test(path)) return true;
  }

  return false;
}

const resources = (await readdir(RESOURCES, { withFileTypes: true }))
  .filter((entry) => entry.isDirectory())
  .map((entry) => join(RESOURCES, entry.name));

// ---------------------------------------------------------------- 1: manifests

console.log('wiring: every Lua file is loaded by its manifest');

for (const resource of resources) {
  const manifest = join(resource, 'fxmanifest.lua');

  let source: string;
  try {
    source = await readFile(manifest, 'utf8');
  } catch {
    fail(`${relative(REPO, resource)}: no fxmanifest.lua`);
    continue;
  }

  const loaded = manifestPaths(source);

  for (const file of await walk(resource)) {
    if (!file.endsWith('.lua')) continue;
    if (file === manifest) continue;

    const path = relative(resource, file).replaceAll('\\', '/');
    if (NOT_LOADED.test(`/${path}`)) continue;

    if (!isLoaded(path, loaded)) {
      fail(
        `${relative(REPO, resource)}/fxmanifest.lua does not load ${path} — ` +
          `the file is dead on a real server`,
      );
    }
  }
}

// ------------------------------------------------------------------ 2-4: routes

console.log('wiring: every route has a schema, a callback and a grant');

const schemaSource = await readFile(SCHEMAS, 'utf8');
const knownSchemas = new Set(
  [...schemaSource.matchAll(/^ {2}([A-Z][A-Za-z0-9]*):\s*\{/gm)].map((match) => match[1] ?? ''),
);

const seed = await readFile(SEED, 'utf8');
const granted = new Set(
  [...seed.matchAll(/\(\s*'[a-z_]+'\s*,\s*'([a-z0-9_.]+)'\s*\)/g)].map((match) => match[1] ?? ''),
);

const core = join(RESOURCES, 'fredpd');

/**
 * Every route name the client will answer for.
 *
 * Two sources, because there are two ways to register one: the `NUI_ROUTES`
 * table in `client/main.lua`, which covers the MDT, and a bare
 * `RegisterNUICallback` in a page's own client file, which is how the garage
 * and the chat do it. Reading only the first would report those as broken.
 */
const nuiRoutes = new Set<string>();

for (const file of await walk(join(core, 'client'))) {
  if (!file.endsWith('.lua')) continue;
  const source = withoutComments(await readFile(file, 'utf8'));

  const table = /NUI_ROUTES\s*(?:<const>\s*)?=\s*\{([\s\S]*?)\n\}/.exec(source);
  for (const quoted of (table?.[1] ?? '').matchAll(/'([^']+)'/g)) {
    nuiRoutes.add(quoted[1] ?? '');
  }

  for (const callback of source.matchAll(/RegisterNUICallback\(\s*'([^']+)'/g)) {
    nuiRoutes.add(callback[1] ?? '');
  }

  // A route the client calls from Lua is just as wired as one the NUI calls.
  // The garage menu, the chat command and the placement editor are all built
  // this way: no NUI at all, `core.call` straight to the gateway.
  for (const call of source.matchAll(/\bcall\(\s*'([^']+)'/g)) {
    nuiRoutes.add(call[1] ?? '');
  }
}

if (nuiRoutes.size === 0) fail('client/: found no route registrations or calls at all');

/** Names from `PUBLIC_ROUTES` that a `routes.lua` was found to declare at all. */
const requiredPublicSeen = new Set<string>();

for (const file of await walk(core)) {
  if (!file.endsWith('routes.lua')) continue;

  const source = await readFile(file, 'utf8');
  const shown = relative(REPO, file);

  // One `route.define({ … })` or `route.public({ … })` call. The definition up
  // to `handler =` is where `name`, `perm` and `schema` live; the slice after
  // it is the handler, read only to see which input fields are actually used.
  //
  // Both tiers are read by one pass because both are routes: same gateway, same
  // envelope, same schema table (ADR-013). The only difference that reaches
  // here is that a public route declares no `perm`, which the grant check below
  // already treats as "nothing to look up".
  const defines = [...source.matchAll(/route\.(define|public)\(\{([\s\S]*?)handler\s*=/g)];

  for (let index = 0; index < defines.length; index += 1) {
    const define = defines[index];
    if (!define) continue;

    const body = define[2] ?? '';
    const tier = define[1] ?? 'define';

    // Everything from this handler to the start of the next route definition.
    const from = (define.index ?? 0) + define[0].length;
    const to = defines[index + 1]?.index ?? source.length;
    const handler = source.slice(from, to);

    // The handler on its own, stopping at the `})` that closes this route call
    // in the first column — how every routes.lua in the tree is written. The
    // slice above runs on to the next route definition and so carries whatever
    // module code sits between the two; check 6 reads a handler and must not
    // convict it of what its neighbour wrote. Comments come out for the same
    // reason: half the point of these handlers is a comment explaining which
    // session field they are not allowed to want.
    const blockEnd = source.indexOf('\n})', from);
    const handlerBody = withoutComments(
      blockEnd === -1 || blockEnd > to ? handler : source.slice(from, blockEnd),
    );

    const name = /\bname\s*=\s*'([^']+)'/.exec(body)?.[1];
    if (name === undefined) continue;

    const schema = /\bschema\s*=\s*'([^']+)'/.exec(body)?.[1];
    if (schema !== undefined && !knownSchemas.has(schema)) {
      fail(`${shown}: route '${name}' names schema '${schema}', which packages/schema does not define`);
    }

    // A route pinned to a placement reads `input.placementId`, and the
    // condition fails closed when it is missing — so a schema without the
    // field makes the route permanently unreachable rather than merely
    // unguarded. This has shipped twice: `evidence.intake`, where the property
    // room counter refused every accept and reject, and the lab routes, where
    // pinning them to the bench refused every analysis.
    // Pinned by the route's own context, or by the handler reading the
    // placement itself — `evidence.transfer` does the latter, because which
    // destinations need a terminal depends on the destination. Either way the
    // field has to survive validation to arrive.
    const pinned =
      /\baccessPoint\s*=\s*'[^']+'/.test(body) || /\binput\.placementId\b/.test(handler);

    if (pinned) {
      if (schema === undefined) {
        fail(`${shown}: route '${name}' is pinned to a placement but declares no schema, so it can never receive a placementId`);
      } else if (!schemaSource.includes('placementId')) {
        fail(`${shown}: route '${name}' is pinned to a placement but no schema declares placementId`);
      } else {
        const declaration = new RegExp(`\\b${schema}:\\s*\\{[\\s\\S]*?\\n {2}\\}`).exec(schemaSource);

        if (declaration && !declaration[0].includes('placementId')) {
          fail(
            `${shown}: route '${name}' is pinned to a placement, but schema '${schema}' has no ` +
              `placementId — the access-point condition fails closed, so every call is refused`,
          );
        }
      }
    }

    const perm = /\bperm\s*=\s*'([^']+)'/.exec(body)?.[1];
    if (perm !== undefined && !granted.has(perm)) {
      fail(
        `${shown}: route '${name}' requires '${perm}', which no group is granted in the seed — ` +
          `nobody can reach this route`,
      );
    }

    if (!nuiRoutes.has(name) && SERVER_CALLED[name] === undefined) {
      fail(
        `${shown}: route '${name}' is not in NUI_ROUTES in client/main.lua — ` +
          `the NUI callback is never registered. Add it, or record it in SERVER_CALLED with a reason`,
      );
    }

    // 6. What route.lua, ADR-013 and spec 3.5.1 all promise about this tier.
    if (tier === 'public') {
      for (const { pattern, what } of PUBLIC_HANDLER_FORBIDDEN) {
        if (pattern.test(handlerBody)) {
          fail(
            `${shown}: public route '${name}' names ${what} in its handler — ` +
              `a public handler holds a server id and no identity, and route.lua, ADR-013 ` +
              `and spec 3.5.1 each state flatly that it therefore cannot reach a record. ` +
              `This is the check that makes those three true. Use an officer route, or change ` +
              `all three claims first`,
          );
        }
      }
    }

    // 7. The conversion back, which is spec 8.10's bug returning.
    const mustBePublic = PUBLIC_ROUTES[name];

    if (mustBePublic !== undefined) {
      requiredPublicSeen.add(name);

      if (tier !== 'public') {
        fail(
          `${shown}: route '${name}' is declared with route.${tier}, but it must be ` +
            `route.public — ${mustBePublic}. A session-bound route answers no_session to ` +
            `every player without an fpd_officers row, which is everyone this route is for ` +
            `(ADR-013)`,
        );
      }
    }
  }
}

for (const [name, why] of Object.entries(PUBLIC_ROUTES)) {
  if (requiredPublicSeen.has(name)) continue;

  fail(
    `routes: '${name}' must exist as a route.public and no routes.lua declares it — ${why}`,
  );
}

// A name in NUI_ROUTES that no route defines is the same mistake mirrored: the
// callback answers and the gateway refuses.
const defined = new Set<string>();
for (const file of await walk(core)) {
  if (!file.endsWith('.lua')) continue;
  const source = await readFile(file, 'utf8');
  for (const match of source.matchAll(/route\.(?:define|public)\(\{[\s\S]*?\bname\s*=\s*'([^']+)'/g)) {
    defined.add(match[1] ?? '');
  }
}

for (const name of nuiRoutes) {
  // `fredpd:`-prefixed names are NUI control messages — close, open, a push —
  // handled by the client itself and never sent to the gateway.
  if (name.startsWith('fredpd:')) continue;

  if (!defined.has(name)) {
    fail(`client/: '${name}' is registered or called, but no route.define or route.public declares it`);
  }
}

// -------------------------------------------- 5: every call reaches a route

console.log('wiring: every fredpd: callback a resource calls is a route');

/**
 * The route name a call names, in the three shapes calls are written in.
 *
 * Checks 2–4 above all begin at a route and ask whether it is reachable. This
 * one begins at the call and asks whether it reaches anything, which is the
 * only direction that catches a call to a route that was never written —
 * `forensics.destroy` in ef88b44, called from `fredpd_forensics/client/
 * destroy.lua`, defined nowhere.
 *
 *   * `lib.callback.await('fredpd:forensics.destroy', …)` and the non-blocking
 *     `lib.callback('fredpd:…', …)` — how a satellite reaches the core, since
 *     ox_lib callbacks are global event names (ADR-011);
 *   * the same name held in a local first, which `report.lua` does;
 *   * `core.call('evidence.collect', …)`, the core client's own wrapper, and
 *     the bare `call('…')` the satellites wrap it in.
 *
 * The first two are found by looking for the literal rather than the call, so
 * the name is caught wherever it is written down. A route name always contains
 * a dot; the dotless `fredpd:` strings — `fredpd:close`, `fredpd:placements`,
 * `fredpd:setupResult` — are net events and push channels, not routes, and
 * requiring the dot leaves them alone without an allowlist that would have to
 * grow with every new push channel.
 */
const CALL_PATTERNS: readonly RegExp[] = [
  /'fredpd:([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)'/g,
  /\bcall\(\s*'([^']+)'/g,
];

for (const file of await walk(RESOURCES)) {
  if (!file.endsWith('.lua')) continue;

  const source = withoutComments(await readFile(file, 'utf8'));
  const shown = relative(REPO, file);

  const called = new Set<string>();

  for (const pattern of CALL_PATTERNS) {
    for (const match of source.matchAll(pattern)) {
      const name = match[1];
      if (name !== undefined && name !== '') called.add(name);
    }
  }

  for (const name of called) {
    // The allowlist records routes reached from Lua rather than from the NUI.
    // Such a route still has to exist, so being listed there is not an excuse
    // here — it only stops check 3 asking for an NUI callback. `fredpd:close`
    // is in it as a control message and has no dot, so it never arrives.
    if (defined.has(name)) continue;

    fail(
      `${shown}: calls 'fredpd:${name}', which no route.define or route.public declares — ` +
        `the call answers nothing on a real server`,
    );
  }
}

if (failures > 0) {
  console.error(`\nwiring check failed: ${failures} problem${failures === 1 ? '' : 's'}`);
  process.exit(1);
}

console.log('wiring check passed');
