import { Router } from 'express';
import { query } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { asyncHandler } from '../middleware/errors.js';




const router = Router();













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


router.get(
  '/auctions/:id/leaderboard',
  asyncHandler(async (req, res) => {
    const result = await query('SELECT * FROM get_leaderboard($1)', [req.params.id]);
    return res.json({ leaderboard: result.rows });
  })
);



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
