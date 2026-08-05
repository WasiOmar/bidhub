import pg from 'pg';

const { Pool } = pg;

const SLOW_QUERY_MS = 100;

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10,
});

// Every route should go through this helper (or pool.connect() directly for
// explicit multi-statement transactions). Nobody creates their own client.
export async function query(text, params) {
  const start = Date.now();
  const result = await pool.query(text, params);
  const duration = Date.now() - start;

  if (process.env.NODE_ENV !== 'production' && duration > SLOW_QUERY_MS) {
    console.warn(`[slow query] ${duration}ms: ${text}`);
  }

  return result;
}

export default pool;
