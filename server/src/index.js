import { fileURLToPath } from 'node:url';
import path from 'node:path';
import dotenv from 'dotenv';

// Resolve .env relative to this file so `npm run dev` behaves the same
// whether it's launched from server/ or the repo root. Tries server/.env
// first, then falls back to the shared root .env used by docker-compose.
const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '../.env') });
dotenv.config({ path: path.resolve(__dirname, '../../.env') });

const { default: app } = await import('./app.js');

const port = process.env.PORT || 4000;

app.listen(port, () => {
  console.log(`BidHub API listening on http://localhost:${port}`);
});

// Batch-close job (CALL close_expired_auctions(), db/03_procedures.sql) is
// opt-in: a demo walking through a manual close shouldn't race a background
// timer also closing the same auctions mid-explanation.
if (process.env.ENABLE_AUCTION_JOB === 'true') {
  const { startCloseAuctionsJob } = await import('./jobs/closeAuctions.js');
  startCloseAuctionsJob(Number(process.env.AUCTION_JOB_INTERVAL_MS) || undefined);
}
