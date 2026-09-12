import express from 'express';
import cors from 'cors';
import rateLimit from 'express-rate-limit';
import { query } from './db.js';
import authRouter from './routes/auth.js';
import categoriesRouter from './routes/categories.js';
import itemsRouter from './routes/items.js';
import auctionsRouter from './routes/auctions.js';
import bidsRouter from './routes/bids.js';
import notificationsRouter from './routes/notifications.js';
import analyticsRouter from './routes/analytics.js';
import { notFoundHandler, errorHandler, asyncHandler } from './middleware/errors.js';

const app = express();

app.use(cors());
app.use(express.json({ limit: '1mb' }));

const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  handler: (req, res) => {
    res
      .status(429)
      .json({ error: { code: 'RATE_LIMITED', message: 'Too many requests, please try again later.' } });
  },
});

app.get(
  '/api/health',
  asyncHandler(async (req, res) => {
    const result = await query('SELECT 1 AS ok');
    res.json({ ok: true, db: result.rows[0].ok === 1 });
  })
);

app.use('/api/auth', authLimiter, authRouter);
app.use('/api/categories', categoriesRouter);
app.use('/api/items', itemsRouter);
app.use('/api/auctions', auctionsRouter);



app.use('/api', bidsRouter);
app.use('/api/notifications', notificationsRouter);
app.use('/api/analytics', analyticsRouter);

app.use(notFoundHandler);
app.use(errorHandler);

export default app;
