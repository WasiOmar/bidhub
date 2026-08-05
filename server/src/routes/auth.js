import { Router } from 'express';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { query } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { asyncHandler } from '../middleware/errors.js';

const router = Router();

const SAFE_USER_COLUMNS = 'user_id, full_name, email, role, created_at';
const SELF_REGISTERABLE_ROLES = new Set(['BUYER', 'SELLER']);

function issueToken(user) {
  return jwt.sign({ sub: user.user_id, email: user.email, role: user.role }, process.env.JWT_SECRET, {
    expiresIn: process.env.JWT_EXPIRES_IN || '24h',
  });
}

router.post(
  '/register',
  asyncHandler(async (req, res) => {
    const { full_name, email, password, role } = req.body || {};

    if (!full_name || !email || !password) {
      return res.status(400).json({
        error: { code: 'VALIDATION_ERROR', message: 'full_name, email and password are required.' },
      });
    }

    if (role && !SELF_REGISTERABLE_ROLES.has(role)) {
      return res.status(400).json({
        error: { code: 'VALIDATION_ERROR', message: 'role must be BUYER or SELLER.' },
      });
    }

    const rounds = Number(process.env.BCRYPT_ROUNDS) || 12;
    const passwordHash = await bcrypt.hash(password, rounds);

    const result = await query(
      `INSERT INTO users (full_name, email, password_hash, role)
       VALUES ($1, $2, $3, COALESCE($4, 'BUYER'))
       RETURNING ${SAFE_USER_COLUMNS}`,
      [full_name, email, passwordHash, role || null]
    );

    const user = result.rows[0];
    const token = issueToken(user);

    return res.status(201).json({ user, token });
  })
);

router.post(
  '/login',
  asyncHandler(async (req, res) => {
    const { email, password } = req.body || {};

    if (!email || !password) {
      return res
        .status(400)
        .json({ error: { code: 'VALIDATION_ERROR', message: 'email and password are required.' } });
    }

    const result = await query(
      `SELECT user_id, full_name, email, password_hash, role, created_at
       FROM users WHERE email = $1`,
      [email]
    );
    const user = result.rows[0];

    if (!user || !(await bcrypt.compare(password, user.password_hash))) {
      return res
        .status(401)
        .json({ error: { code: 'INVALID_CREDENTIALS', message: 'Invalid email or password.' } });
    }

    delete user.password_hash;
    const token = issueToken(user);

    return res.json({ user, token });
  })
);

router.get(
  '/me',
  requireAuth,
  asyncHandler(async (req, res) => {
    const result = await query(`SELECT ${SAFE_USER_COLUMNS} FROM users WHERE user_id = $1`, [
      req.user.user_id,
    ]);

    if (!result.rows[0]) {
      return res.status(404).json({ error: { code: 'NOT_FOUND', message: 'User not found.' } });
    }

    return res.json({ user: result.rows[0] });
  })
);

export default router;
