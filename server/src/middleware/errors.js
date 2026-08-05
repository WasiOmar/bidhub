// Maps PostgreSQL SQLSTATEs (and the AU00x business codes raised by
// place_bid) onto HTTP responses. This is the only place that translates
// database errors into the API's error envelope.
const SQLSTATE_MAP = {
  AU001: { status: 400, code: 'AU001', fallback: 'Bid does not meet the minimum increment.' },
  AU002: { status: 409, code: 'AU002', fallback: 'Auction is not active.' },
  AU003: { status: 403, code: 'AU003', fallback: 'Sellers cannot bid on their own auction.' },
  AU004: { status: 404, code: 'AU004', fallback: 'Auction not found.' },
  23505: { status: 409, code: 'UNIQUE_VIOLATION', fallback: 'A record with these details already exists.' },
  23503: { status: 400, code: 'FOREIGN_KEY_VIOLATION', fallback: 'Referenced record does not exist.' },
  23514: { status: 400, code: 'CHECK_VIOLATION', fallback: 'Value violates a data constraint.' },
};

export function notFoundHandler(req, res) {
  res.status(404).json({ error: { code: 'NOT_FOUND', message: 'Route not found' } });
}

// eslint-disable-next-line no-unused-vars
export function errorHandler(err, req, res, next) {
  const mapped = err.code && SQLSTATE_MAP[err.code];

  if (mapped) {
    return res.status(mapped.status).json({
      error: { code: mapped.code, message: err.message || mapped.fallback },
    });
  }

  console.error(err);
  return res.status(500).json({
    error: { code: 'INTERNAL_ERROR', message: 'Something went wrong.' },
  });
}

// Wraps an async route handler so rejected promises reach errorHandler
// instead of crashing the process.
export function asyncHandler(fn) {
  return (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);
}
