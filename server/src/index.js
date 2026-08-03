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
