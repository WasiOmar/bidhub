import { Router } from 'express';
import { query } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { asyncHandler } from '../middleware/errors.js';

const router = Router();




router.get(
  '/',
  requireAuth,
  asyncHandler(async (req, res) => {
    const result = await query(
      `SELECT notification_id, type, title, message, auction_id, is_read, created_at
         FROM notifications
        WHERE user_id = $1
        ORDER BY is_read ASC, created_at DESC`,
      [req.user.user_id]
    );

    return res.json({ notifications: result.rows });
  })
);

router.patch(
  '/:id/read',
  requireAuth,
  asyncHandler(async (req, res) => {
    const result = await query(
      `UPDATE notifications SET is_read = true
        WHERE notification_id = $1 AND user_id = $2
        RETURNING notification_id, is_read`,
      [req.params.id, req.user.user_id]
    );

    if (!result.rows[0]) {
      return res.status(404).json({ error: { code: 'NOT_FOUND', message: 'Notification not found.' } });
    }

    return res.json({ notification: result.rows[0] });
  })
);

export default router;
