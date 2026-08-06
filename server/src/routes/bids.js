import { Router } from 'express';
import { query } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { asyncHandler } from '../middleware/errors.js';

// This router owns three paths under different prefixes (/api/auctions/:id/bids,
// /api/auctions/:id/leaderboard, /api/me/bids), so it is mounted at /api
// directly rather than nested under an /auctions-prefixed router.
const router = Router();

// POST /api/auctions/:id/bids
//
// This is the whole handler on purpose: CALL place_bid and nothing else.
// place_bid() (db/03_procedures.sql) already validates status/end_time,
// self-bidding, and the minimum amount, each with a typed SQLSTATE
// (AU001-AU004) -- re-checking any of that here would just be a second
// source of truth that can drift from the first. The `amount` check below
// is a request-shape check (is a value present at all), not a business-rule
// check (is it big enough) -- that distinction matters: the latter is
// entirely place_bid's job. Letting the procedure raise and errors.js
// translate its SQLSTATE into the right HTTP status is exactly what that
// middleware exists for.
router.post(
  '/auctions/:id/bids',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { amount } = req.body || {};

    if (amount === undefined || amount === null) {
      return res.status(400).json({ error: { code: 'VALIDATION_ERROR', message: 'amount is required.' } });
    }

    await query('CALL place_bid($1, $2, $3)', [req.user.user_id, req.params.id, amount]);

    return res.status(201).json({ ok: true });
  })
);

// GET /api/auctions/:id/leaderboard
router.get(
  '/auctions/:id/leaderboard',
  asyncHandler(async (req, res) => {
    const result = await query('SELECT * FROM get_leaderboard($1)', [req.params.id]);
    return res.json({ leaderboard: result.rows });
  })
);

// GET /api/me/bids -- the caller's own bid history, newest first, with
// enough auction/item context to render without a second round trip.
router.get(
  '/me/bids',
  requireAuth,
  asyncHandler(async (req, res) => {
    const result = await query(
      `SELECT b.bid_id, b.auction_id, b.amount, b.placed_at,
              a.status AS auction_status, a.end_time, a.winning_bid_id,
              i.title AS item_title,
              (a.winning_bid_id IS NOT NULL AND b.bid_id = a.winning_bid_id) AS won
         FROM bids b
         JOIN auctions a ON a.auction_id = b.auction_id
         JOIN items i ON i.item_id = a.item_id
        WHERE b.bidder_id = $1
        ORDER BY b.placed_at DESC`,
      [req.user.user_id]
    );

    return res.json({ bids: result.rows });
  })
);

export default router;
