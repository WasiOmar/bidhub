import pool from '../db.js';

const DEFAULT_INTERVAL_MS = 60_000;








async function runOnce() {
  const client = await pool.connect();
  const notices = [];

  const onNotice = (notice) => {
    notices.push(notice.message);
  };
  client.on('notice', onNotice);

  try {
    await client.query('CALL open_scheduled_auctions()');
    await client.query('CALL close_expired_auctions()');
    console.log(`[auction-close-job] ${notices.join('; ') || 'ran (no notice captured)'}`);
  } catch (err) {
    console.error('[auction-close-job] failed:', err.message);
  } finally {
    client.removeListener('notice', onNotice);
    client.release();
  }
}

export function startCloseAuctionsJob(intervalMs = DEFAULT_INTERVAL_MS) {
  console.log(`[auction-close-job] started, interval=${intervalMs}ms`);
  runOnce();
  return setInterval(runOnce, intervalMs);
}
