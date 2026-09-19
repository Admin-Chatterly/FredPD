import {
  forceCenter,
  forceCollide,
  forceLink,
  forceManyBody,
  forceSimulation,
  type SimulationNodeDatum,
} from "d3-force"

export type LayoutNode = SimulationNodeDatum & { id: string }
export type LayoutLink = { source: string; target: string }
export type LayoutPositions = Map<string, { x: number; y: number }>

/**
 * d3-force reaches for randomness whenever two nodes land on the same point, so
 * it is given a seeded generator instead of Math.random. That makes the layout
 * reproducible, which keeps the server and client renders identical and means
 * the same board opens the same way every time.
 */
export function seededRandom(seed: number): () => number {
  let state = seed >>> 0
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0
    return state / 4294967296
  }
}

/**
 * The simulation is run to completion before anything is drawn rather than
 * animated into place: the board should open settled, and a running simulation
 * fights the officer dragging nodes around.
 */
export function layoutGraph(nodes: LayoutNode[], links: LayoutLink[]): LayoutPositions {
  // The simulation mutates what it is given, so it works on copies.
  const simulationNodes: LayoutNode[] = nodes.map((n) => ({ id: n.id }))
  const simulation = forceSimulation(simulationNodes)
    .randomSource(seededRandom(0x5eed))
    .force(
      "link",
      forceLink<LayoutNode, LayoutLink & { source: string | LayoutNode; target: string | LayoutNode }>(
        links.map((l) => ({ ...l }))
      )
        .id((d) => d.id)
        .distance(220)
        .strength(0.4)
    )
    .force("charge", forceManyBody().strength(-1200))
    .force("collide", forceCollide(110))
    .force("center", forceCenter(0, 0))
    .stop()

  simulation.tick(400)
  return new Map(simulationNodes.map((n) => [n.id, { x: n.x ?? 0, y: n.y ?? 0 }]))
}
