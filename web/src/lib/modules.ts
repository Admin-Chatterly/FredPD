/**
 * The modules the server said this session may open (`session.get`,
 * `fredpd:permissions`), for a screen deciding whether to offer a hand-off
 * to another module ("Book this person in"). App keeps it current.
 *
 * Drawing only: a module left off this list is refused by the server anyway,
 * and nothing here grants anything (invariant 4).
 */
let allowed = new Set<string>();

export function setAllowedModules(modules: readonly string[]): void {
  allowed = new Set(modules);
}

export function mayOpen(module: string): boolean {
  return allowed.has(module);
}
