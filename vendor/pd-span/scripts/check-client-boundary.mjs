#!/usr/bin/env node
/**
 * A function exported from a "use client" module is a client reference. A
 * server component may render it as a component or pass it as a prop, but
 * calling it throws at render: "Attempted to call x() from the server".
 *
 * `next build` only catches this on a statically rendered route, and every page
 * in this app is dynamic, so it reached production once already. This walks the
 * import graph instead and fails on a server module importing a lower-case
 * (so: not a component) runtime binding out of a client module.
 */
import { readFileSync, readdirSync, statSync } from "node:fs"
import { dirname, join, relative, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const roots = ["app", "components", "lib"]

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry)
    if (statSync(path).isDirectory()) walk(path, out)
    else if (/\.tsx?$/.test(entry)) out.push(path)
  }
  return out
}

const files = roots.flatMap((r) => walk(join(root, r)))
const sources = new Map(files.map((f) => [f, readFileSync(f, "utf8")]))
const isClient = (file) => /^\s*(["'])use client\1/.test(sources.get(file) ?? "")

/** Mirrors the tsconfig paths this project uses: "@/" is the repo root. */
function resolveImport(spec, importer) {
  let base
  if (spec.startsWith("@/")) base = join(root, spec.slice(2))
  else if (spec.startsWith(".")) base = resolve(dirname(importer), spec)
  else return null
  for (const candidate of [`${base}.tsx`, `${base}.ts`, join(base, "index.tsx"), join(base, "index.ts")]) {
    if (sources.has(candidate)) return candidate
  }
  return null
}

const IMPORT = /import\s+(type\s+)?\{([^}]*)\}\s+from\s+["']([^"']+)["']/gs
const problems = []

for (const [file, text] of sources) {
  if (isClient(file)) continue
  for (const [, typeOnly, names, spec] of text.matchAll(IMPORT)) {
    if (typeOnly) continue
    const target = resolveImport(spec, file)
    if (!target || !isClient(target)) continue
    const values = names
      .split(",")
      .map((n) => n.trim().split(/\s+as\s+/)[0].trim())
      .filter((n) => n && !n.startsWith("type ") && /^[a-z]/.test(n))
    if (values.length > 0) {
      const line = text.slice(0, text.indexOf(spec)).split("\n").length
      problems.push(
        `${relative(root, file)}:${line}: imports ${values.join(", ")} from the client module ` +
          `${relative(root, target)}. Move the shared code into a module with no "use client".`
      )
    }
  }
}

if (problems.length > 0) {
  console.error(problems.join("\n"))
  console.error(`\ncheck-client-boundary: ${problems.length} problem(s)`)
  process.exit(1)
}
console.log("check-client-boundary: OK")
