import { fileURLToPath } from 'node:url';
import path from 'node:path';
import dotenv from 'dotenv';




const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '../.env') });
dotenv.config({ path: path.resolve(__dirname, '../../.env') });

const { default: app } = await import('./app.js');

const port = process.env.PORT || 4000;

app.listen(port, () => {
  console.log(`BidHub API listening on http://localhost:${port}`);
});




if (process.env.ENABLE_AUCTION_JOB === 'true') {
  const { startCloseAuctionsJob } = await import('./jobs/closeAuctions.js');
  startCloseAuctionsJob(Number(process.env.AUCTION_JOB_INTERVAL_MS) || undefined);
}
