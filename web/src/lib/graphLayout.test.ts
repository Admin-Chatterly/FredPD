import { describe, expect, it } from 'vitest';

import { BOX_H, BOX_W, layoutGraph, seededRandom } from './graphLayout';

describe('graph layout', () => {
  it('opens the same board the same way every time', () => {
    const nodes = [{ id: 'p1' }, { id: 'p2' }, { id: 'o1' }];
    const links = [
      { source: 'p1', target: 'o1' },
      { source: 'p2', target: 'o1' },
    ];

    expect([...layoutGraph(nodes, links)]).toEqual([...layoutGraph(nodes, links)]);
  });

  it('keeps linked nodes closer than unlinked ones, and never stacks two on one point', () => {
    const nodes = ['a', 'b', 'c', 'd', 'e'].map((id) => ({ id }));
    const positions = layoutGraph(nodes, [{ source: 'a', target: 'b' }]);

    const distance = (x: string, y: string): number => {
      const p = positions.get(x)!;
      const q = positions.get(y)!;
      return Math.hypot(p.x - q.x, p.y - q.y);
    };

    expect(distance('a', 'b')).toBeLessThan(distance('a', 'e'));
    for (const x of ['a', 'b', 'c', 'd', 'e']) {
      for (const y of ['a', 'b', 'c', 'd', 'e']) {
        if (x !== y) expect(distance(x, y)).toBeGreaterThan(20);
      }
    }
  });

  it('ignores a link to a node that is not on the board', () => {
    const positions = layoutGraph([{ id: 'a' }], [{ source: 'a', target: 'ghost' }]);
    expect([...positions.keys()]).toEqual(['a']);
  });

  it('draws numbers between 0 and 1 from its seed', () => {
    const random = seededRandom(1);
    for (let i = 0; i < 100; i += 1) {
      const value = random();
      expect(value).toBeGreaterThanOrEqual(0);
      expect(value).toBeLessThan(1);
    }
  });

  it('never draws one node box over another, even on a crowded board', () => {
    const nodes = Array.from({ length: 120 }, (_, i) => ({ id: String(i) }));
    const links = Array.from({ length: 160 }, (_, i) => ({ source: String(i % 120), target: String((i * 7) % 120) }));
    const positions = [...layoutGraph(nodes, links).values()];

    for (let a = 0; a < positions.length; a += 1) {
      for (let b = a + 1; b < positions.length; b += 1) {
        const p = positions[a]!;
        const q = positions[b]!;
        const overlaps = Math.abs(p.x - q.x) < BOX_W && Math.abs(p.y - q.y) < BOX_H;
        expect(overlaps).toBe(false);
      }
    }
  });
});
