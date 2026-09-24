import { describe, expect, it } from 'vitest';
import { parseIntent, peekIntent, setIntent, takeIntent } from './intent';

describe('parseIntent', () => {
  it('reads a module, a tab and a query', () => {
    expect(parseIntent({ module: 'records', tab: 'query', term: 'ABC123', type: 'plate' })).toEqual({
      module: 'records',
      tab: 'query',
      term: 'ABC123',
      type: 'plate',
    });
  });

  it('ignores what is not an intent', () => {
    expect(parseIntent(undefined)).toBeNull();
    expect(parseIntent('records')).toBeNull();
    expect(parseIntent({ tab: 'query' })).toBeNull();
  });

  it('drops fields of the wrong type', () => {
    expect(parseIntent({ module: 'records', term: 42 })).toEqual({ module: 'records' });
  });
});

describe('the pending intent', () => {
  it('is taken once', () => {
    setIntent({ module: 'records', tab: 'query', term: 'x' });

    expect(peekIntent()?.term).toBe('x');
    expect(takeIntent()?.term).toBe('x');
    expect(takeIntent()).toBeNull();
  });
});
