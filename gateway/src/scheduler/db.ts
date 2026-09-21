import mysql from 'mysql2/promise';

/**
 * The gateway's own MariaDB connection (spec 3.2: "gateway (Node.js) ...
 * mysql2 ... MariaDB"), used by the scheduler alone.
 *
 * Every query below is parameterized (invariant 8, same rule the Lua side
 * follows) — nothing here ever concatenates a value into a statement, even
 * though every value the scheduler writes is one it computed itself rather
 * than one a caller sent.
 */
export type SqlValue = string | number | null;

export interface SchedulerDb {
  execute(sql: string, values?: SqlValue[]): Promise<number>;
  end(): Promise<void>;
}

/** @param databaseUrl `mysql://user:pass@host:port/db`, the `DATABASE_URL` `.env.example` documents. */
export function connect(databaseUrl: string): SchedulerDb {
  const pool = mysql.createPool({
    uri: databaseUrl,
    connectionLimit: 2,
  });

  return {
    async execute(sql, values = []) {
      const [result] = await pool.execute(sql, values);
      return (result as mysql.ResultSetHeader).affectedRows ?? 0;
    },
    async end() {
      await pool.end();
    },
  };
}
