import { Router } from 'express';
import { query } from '../db.js';
import { asyncHandler } from '../middleware/errors.js';

const router = Router();

// get_category_tree() (db/04_queries.sql, recursive CTE) returns flat,
// depth-first rows. Nesting them into a real tree happens here in JS rather
// than in the database, so the recursive CTE itself stays reusable as a flat
// row source for the breadcrumb and item-count routines too.
function nestCategories(rows) {
  const byId = new Map();
  const roots = [];

  for (const row of rows) {
    byId.set(row.category_id, { ...row, children: [] });
  }

  for (const row of rows) {
    const node = byId.get(row.category_id);
    if (row.parent_id && byId.has(row.parent_id)) {
      byId.get(row.parent_id).children.push(node);
    } else {
      roots.push(node);
    }
  }

  return roots;
}

// GET /api/categories/tree?root_id= -- the whole forest when root_id is
// omitted, or just that category's subtree when supplied.
router.get(
  '/tree',
  asyncHandler(async (req, res) => {
    const rootId = req.query.root_id ? Number(req.query.root_id) : null;

    if (req.query.root_id && Number.isNaN(rootId)) {
      return res.status(400).json({ error: { code: 'VALIDATION_ERROR', message: 'root_id must be numeric.' } });
    }

    const result = await query('SELECT * FROM get_category_tree($1)', [rootId]);
    return res.json({ categories: nestCategories(result.rows) });
  })
);

// GET /api/categories/:id/breadcrumb -- root-first list from
// get_category_breadcrumb() (same recursive technique, walking upward).
router.get(
  '/:id/breadcrumb',
  asyncHandler(async (req, res) => {
    const categoryId = Number(req.params.id);

    if (Number.isNaN(categoryId)) {
      return res.status(400).json({ error: { code: 'VALIDATION_ERROR', message: 'id must be numeric.' } });
    }

    const result = await query('SELECT * FROM get_category_breadcrumb($1)', [categoryId]);
    return res.json({ breadcrumb: result.rows });
  })
);

export default router;
