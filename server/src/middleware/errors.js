


const SQLSTATE_MAP = {
  AU001: { status: 400, code: 'AU001', fallback: 'Bid does not meet the minimum increment.', passThrough: true },
  AU002: { status: 409, code: 'AU002', fallback: 'Auction is not active.', passThrough: true },
  AU003: { status: 403, code: 'AU003', fallback: 'Sellers cannot bid on their own auction.', passThrough: true },
  AU004: { status: 404, code: 'AU004', fallback: 'Auction not found.', passThrough: true },
  23505: { status: 409, code: 'UNIQUE_VIOLATION', fallback: 'A record with these details already exists.' },
  23503: { status: 400, code: 'FOREIGN_KEY_VIOLATION', fallback: 'Referenced record does not exist.' },
  23514: { status: 400, code: 'CHECK_VIOLATION', fallback: 'Value violates a data constraint.' },
  23502: { status: 400, code: 'VALIDATION_ERROR', fallback: 'A required value is missing.' },
  '22P02': { status: 400, code: 'VALIDATION_ERROR', fallback: 'A value has the wrong format.' },
  22003: { status: 400, code: 'VALIDATION_ERROR', fallback: 'A number is out of range.' },
  22007: { status: 400, code: 'VALIDATION_ERROR', fallback: 'A date or time value is invalid.' },
  22008: { status: 400, code: 'VALIDATION_ERROR', fallback: 'A date or time value is out of range.' },
};

// Only the AU00x messages are written for end users (RAISE EXCEPTION in place_bid).
// A raw PostgreSQL integrity message names tables and constraints, so it is
// replaced by a per-constraint sentence or the generic fallback.
const CONSTRAINT_MESSAGES = {
  uq_users_email: 'An account with this email already exists.',
  chk_users_email_format: 'Please enter a valid email address.',
  uq_auctions_item: 'This item already has an auction.',
  chk_auctions_end_after_start: 'The end time must be after the start time.',
  chk_auctions_starting_price_positive: 'The starting price must be greater than zero.',
  chk_auctions_bid_increment_positive: 'The bid increment must be greater than zero.',
  chk_auctions_reserve_at_least_starting: 'The reserve price cannot be below the starting price.',
  chk_bids_amount_positive: 'A bid must be greater than zero.',
  fk_items_category: 'That category does not exist.',
  fk_auctions_item: 'That item does not exist.',
};

export function notFoundHandler(req, res) {
  res.status(404).json({ error: { code: 'NOT_FOUND', message: 'Route not found' } });
}


export function errorHandler(err, req, res, next) {
  if (res.headersSent) {
    return next(err);
  }

  if (err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: { code: 'VALIDATION_ERROR', message: 'Request body is not valid JSON.' } });
  }

  if (err.type === 'entity.too.large') {
    return res.status(413).json({ error: { code: 'PAYLOAD_TOO_LARGE', message: 'Request body is too large.' } });
  }

  const mapped = err.code && SQLSTATE_MAP[err.code];

  if (mapped) {
    const message = mapped.passThrough
      ? err.message || mapped.fallback
      : CONSTRAINT_MESSAGES[err.constraint] || mapped.fallback;
    return res.status(mapped.status).json({ error: { code: mapped.code, message } });
  }

  console.error(err);
  return res.status(500).json({
    error: { code: 'INTERNAL_ERROR', message: 'Something went wrong.' },
  });
}



export function asyncHandler(fn) {
  return (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);
}
