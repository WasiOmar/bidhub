import { Router } from 'express';
import { query } from '../db.js';
import { asyncHandler } from '../middleware/errors.js';

const router = Router();

// Straight reads off the window-function views (db/04_queries.sql) -- no
// business logic here, the ranking/running-total math is entirely the
// view's job.
router.get(
  '/top-bidders',
  asyncHandler(async (req, res) => {
    const result = await query('SELECT * FROM v_top_bidders ORDER BY rank ASC LIMIT 50');
    return res.json({ top_bidders: result.rows });
  })
);

router.get(
  '/seller-revenue',
  asyncHandler(async (req, res) => {
    const result = await query('SELECT * FROM v_seller_revenue ORDER BY seller_id, created_at');
    return res.json({ seller_revenue: result.rows });
  })
);

export default router;
