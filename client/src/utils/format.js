const moneyFormatter = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });

const compactMoneyFormatter = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  notation: 'compact',
  maximumSignificantDigits: 3,
});

export function formatMoney(amount) {
  return moneyFormatter.format(Number(amount));
}

export function formatMoneyCompact(amount) {
  return compactMoneyFormatter.format(Number(amount));
}

export function formatDateTime(value) {
  return new Date(value).toLocaleString();
}

export function formatTime(value) {
  return new Date(value).toLocaleTimeString();
}

export function formatShortDate(value) {
  return new Date(value).toLocaleDateString([], { month: 'short', day: 'numeric' });
}

const REMAINING_UNITS = [
  ['d', 86400],
  ['h', 3600],
  ['m', 60],
  ['s', 1],
];

// Starts at the largest non-zero unit and shows `parts` units: 2d 20h 10m, 5h 12m 30s, 12m 30s.
export function formatRemaining(ms, parts = 3) {
  let rest = Math.max(0, Math.floor(ms / 1000));
  const values = REMAINING_UNITS.map(([label, size]) => {
    const value = Math.floor(rest / size);
    rest -= value * size;
    return `${value}${label}`;
  });
  const first = values.findIndex((v) => parseInt(v, 10) > 0);
  if (first === -1) return '0s';
  return values.slice(first, first + parts).join(' ');
}

export function pluralize(count, singular, plural = `${singular}s`) {
  return count === 1 ? singular : plural;
}
