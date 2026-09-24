/**
 * A force-directed layout for the link diagram (spec 10.6), after PD-Span's
 * `lib/board-layout.ts` -- without d3: the NUI ships no graph library, and a
 * few hundred nodes need forty lines, not a dependency.
 *
 * Run to completion before anything is drawn rather than animated: the board
 * opens settled, and a moving simulation fights an officer reading it. Seeded,
 * so the same board opens the same way every time.
 */

export interface LayoutNode {
  id: string;
}

export interface LayoutLink {
  source: string;
  target: string;
}

export type LayoutPositions = Map<string, { x: number; y: number }>;

/** A linear congruential generator: reproducible where `Math.random` is not. */
export function seededRandom(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 4294967296;
  };
}

const LINK_DISTANCE = 180;
const REPULSION = 250_000;
/** Fewer passes for a big board: each is quadratic, and a board of three
 *  hundred settles well enough in half the steps (spec 12, a screen opens fast). */
function iterationsFor(count: number): number {
  return count > 150 ? 150 : 300;
}

export function layoutGraph(nodes: LayoutNode[], links: LayoutLink[]): LayoutPositions {
  const random = seededRandom(0x5eed);
  const radius = 60 * Math.sqrt(nodes.length + 1);

  const points = nodes.map((node) => ({
    id: node.id,
    x: (random() - 0.5) * radius * 2,
    y: (random() - 0.5) * radius * 2,
    dx: 0,
    dy: 0,
  }));
  const index = new Map(points.map((point, i) => [point.id, i]));
  const edges = links
    .map((link) => [index.get(link.source), index.get(link.target)] as const)
    .filter((edge): edge is readonly [number, number] => edge[0] !== undefined && edge[1] !== undefined);

  const iterations = iterationsFor(points.length);

  for (let step = 0; step < iterations; step += 1) {
    // Cools from a long stride to a short one, so it settles rather than orbits.
    const heat = 1 - step / iterations;

    for (const point of points) {
      point.dx = 0;
      point.dy = 0;
    }

    // Every pair pushes apart.
    for (let a = 0; a < points.length; a += 1) {
      const p = points[a]!;
      for (let b = a + 1; b < points.length; b += 1) {
        const q = points[b]!;
        let x = p.x - q.x;
        let y = p.y - q.y;
        let distance2 = x * x + y * y;
        if (distance2 < 1) {
          x = random() - 0.5;
          y = random() - 0.5;
          distance2 = 1;
        }
        const force = REPULSION / distance2;
        const distance = Math.sqrt(distance2);
        p.dx += (x / distance) * force;
        p.dy += (y / distance) * force;
        q.dx -= (x / distance) * force;
        q.dy -= (y / distance) * force;
      }
    }

    // Every link pulls toward its length.
    for (const [a, b] of edges) {
      const p = points[a]!;
      const q = points[b]!;
      const x = q.x - p.x;
      const y = q.y - p.y;
      const distance = Math.max(1, Math.sqrt(x * x + y * y));
      const force = (distance - LINK_DISTANCE) * 0.5;
      p.dx += (x / distance) * force;
      p.dy += (y / distance) * force;
      q.dx -= (x / distance) * force;
      q.dy -= (y / distance) * force;
    }

    // A gentle pull to the middle keeps unconnected nodes on the page.
    for (const point of points) {
      point.dx -= point.x * 0.02;
      point.dy -= point.y * 0.02;

      const length = Math.sqrt(point.dx * point.dx + point.dy * point.dy) || 1;
      const stride = Math.min(length, 40 * heat + 1);
      point.x += (point.dx / length) * stride;
      point.y += (point.dy / length) * stride;
    }
  }

  return new Map(points.map((point) => [point.id, { x: point.x, y: point.y }]));
}
