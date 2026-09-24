import { describe, expect, it } from 'vitest';
import { parseCommand } from './command';

describe('parseCommand', () => {
  it('runs a plate query in either language', () => {
    expect(parseCommand('P abc123')).toEqual({ kind: 'query', type: 'plate', term: 'abc123' });
    expect(parseCommand('reg ABC 123')).toEqual({ kind: 'query', type: 'plate', term: 'ABC 123' });
  });

  it('keeps a name as typed, commas and all', () => {
    expect(parseCommand('N Doe, John 1990-01-01')).toEqual({
      kind: 'query',
      type: 'person',
      term: 'Doe, John 1990-01-01',
    });
  });

  it('knows the other registers', () => {
    expect(parseCommand('VAP SN-1')).toMatchObject({ type: 'firearm' });
    expect(parseCommand('TEL 555-0134')).toMatchObject({ type: 'phone' });
    expect(parseCommand('ADR Grove St')).toMatchObject({ type: 'address' });
  });

  it('asks for a term rather than searching for nothing', () => {
    expect(parseCommand('P')).toEqual({ kind: 'invalid', reason: 'needs_term' });
    expect(parseCommand('   ')).toEqual({ kind: 'invalid', reason: 'empty' });
  });

  it('sets a unit status from its radio code', () => {
    expect(parseCommand('ST ER')).toEqual({ kind: 'status', status: 'en_route' });
    expect(parseCommand('st os')).toEqual({ kind: 'status', status: 'on_scene' });
    expect(parseCommand('ST OOS')).toEqual({ kind: 'status', status: 'out_of_service' });
    expect(parseCommand('ST XX')).toEqual({ kind: 'invalid', reason: 'unknown_status' });
  });

  it('attaches to the nearest call', () => {
    expect(parseCommand('ATT')).toEqual({ kind: 'attach' });
    expect(parseCommand('till')).toEqual({ kind: 'attach' });
  });

  it('clears the current call, as handled on scene unless told otherwise', () => {
    expect(parseCommand('CLR')).toEqual({ kind: 'clear', disposition: 'handled_on_scene' });
    expect(parseCommand('KLAR ARR')).toEqual({ kind: 'clear', disposition: 'arrest_made' });
    expect(parseCommand('CLR report taken')).toEqual({ kind: 'clear', disposition: 'report_taken' });
    expect(parseCommand('CLR nonsense')).toEqual({ kind: 'invalid', reason: 'unknown_disposition' });
  });

  it('says a named but unbuilt command is not built, rather than searching for it', () => {
    expect(parseCommand('MSG 1-ADAM-12 on my way')).toEqual({ kind: 'invalid', reason: 'not_built' });
    expect(parseCommand('NY R')).toEqual({ kind: 'invalid', reason: 'not_built' });
    expect(parseCommand('C 0042')).toEqual({ kind: 'invalid', reason: 'not_built' });
  });

  it('treats anything else as a search', () => {
    expect(parseCommand('ABC123')).toEqual({ kind: 'query', term: 'ABC123' });
  });
});
