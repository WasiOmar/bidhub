import { Router } from 'express';
import { query } from '../db.js';
import { requireAuth, requireRole } from '../middleware/auth.js';
import { asyncHandler } from '../middleware/errors.js';

const router = Router();

const ITEM_COLUMNS = `
  i.item_id, i.seller_id, i.category_id, i.title, i.description, i.condition,
  i.attributes, i.image_url, i.created_at,
  c.name AS category_name, u.full_name AS seller_name
`;

const ITEM_JOINS = `
  FROM items i
  JOIN categories c ON c.category_id = i.category_id
  JOIN users u ON u.user_id = i.seller_id
`;


router.get(
  '/',
  asyncHandler(async (req, res) => {
    const { category, seller, q } = req.query;
    const conditions = [];
    const params = [];

    if (category) {
      
      
      
      
      params.push(Number(category));
      conditions.push(`i.category_id IN (SELECT category_id FROM get_category_tree($${params.length}))`);
    }

    if (seller) {
      params.push(Number(seller));
      conditions.push(`i.seller_id = $${params.length}`);
    }

    if (q) {
      params.push(`%${q}%`);
      conditions.push(`i.title ILIKE $${params.length}`);
    }

    const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
    const pageSize = Math.min(Number(req.query.limit) || 20, 100);
    const page = Math.max(Number(req.query.page) || 1, 1);
    const offset = (page - 1) * pageSize;

    params.push(pageSize, offset);

    const result = await query(
      `SELECT ${ITEM_COLUMNS} ${ITEM_JOINS} ${where}
        ORDER BY i.created_at DESC
        LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params
    );

    return res.json({ items: result.rows, page, limit: pageSize });
  })
);




router.post(
  '/',
  requireAuth,
  requireRole('SELLER'),
  asyncHandler(async (req, res) => {
    const { category_id, title, description, condition, attributes, image_url } = req.body || {};

    if (!category_id || !title) {
      return res.status(400).json({
        error: { code: 'VALIDATION_ERROR', message: 'category_id and title are required.' },
      });
    }

    const result = await query(
      `INSERT INTO items (seller_id, category_id, title, description, condition, attributes, image_url)
       VALUES ($1, $2, $3, $4, COALESCE($5, 'USED'), COALESCE($6, '{}'::jsonb), $7)
       RETURNING item_id, seller_id, category_id, title, description, condition, attributes, image_url, created_at`,
      [
        req.user.user_id,
        category_id,
        title,
        description || null,
        condition || null,
        attributes ? JSON.stringify(attributes) : null,
        image_url || null,
      ]
    );

    return res.status(201).json({ item: result.rows[0] });
  })
);


router.get(
  '/:id',
  asyncHandler(async (req, res) => {
    const result = await query(`SELECT ${ITEM_COLUMNS} ${ITEM_JOINS} WHERE i.item_id = $1`, [
      req.params.id,
    ]);

    if (!result.rows[0]) {
      return res.status(404).json({ error: { code: 'NOT_FOUND', message: 'Item not found.' } });
    }

    return res.json({ item: result.rows[0] });
  })
);

export default router;
