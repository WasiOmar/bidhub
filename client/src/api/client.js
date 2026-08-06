// Thin fetch wrapper: attaches the JWT, parses the server's
// { error: { code, message } } envelope, and translates the DB's typed
// SQLSTATE codes (AU001-AU004, from place_bid — db/03_procedures.sql) into
// copy a bidder actually understands, rather than a generic "request
// failed". Every screen that calls the API goes through this file so that
// translation lives in exactly one place.

const BASE_URL = `${import.meta.env.VITE_API_URL || 'http://localhost:4000'}/api`;

const TOKEN_KEY = 'bidhub_token';

export function getToken() {
  return localStorage.getItem(TOKEN_KEY);
}

export function setToken(token) {
  if (token) {
    localStorage.setItem(TOKEN_KEY, token);
  } else {
    localStorage.removeItem(TOKEN_KEY);
  }
}

// Maps the typed codes raised by place_bid (db/03_procedures.sql) onto
// copy that names the actual problem. Every other error code just surfaces
// the server's own message, which the API's error middleware
// (server/src/middleware/errors.js) already writes to be user-facing.
const CODE_MESSAGES = {
  AU001: (message) => {
    const match = message && message.match(/minimum required bid of ([\d.]+)/);
    return match ? `Your bid is too low — minimum is ${match[1]}.` : 'Your bid is below the required minimum.';
  },
  AU002: () => 'This auction has ended or is not open for bidding.',
  AU003: () => 'You cannot bid on your own listing.',
  AU004: () => 'This auction no longer exists.',
};

export class ApiError extends Error {
  constructor(code, message, status) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

export async function apiFetch(path, { method = 'GET', body, headers = {} } = {}) {
  const token = getToken();

  const response = await fetch(`${BASE_URL}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  const isJson = response.headers.get('content-type')?.includes('application/json');
  const payload = isJson ? await response.json().catch(() => null) : null;

  if (!response.ok) {
    const code = payload?.error?.code || 'UNKNOWN_ERROR';
    const rawMessage = payload?.error?.message || response.statusText;
    const friendly = CODE_MESSAGES[code]?.(rawMessage) || rawMessage;
    throw new ApiError(code, friendly, response.status);
  }

  return payload;
}

export const api = {
  get: (path) => apiFetch(path),
  post: (path, body) => apiFetch(path, { method: 'POST', body }),
  patch: (path, body) => apiFetch(path, { method: 'PATCH', body }),
};
