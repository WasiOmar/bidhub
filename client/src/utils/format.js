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

export function pluralize(count, singular, plural = `${singular}s`) {
  return count === 1 ? singular : plural;
}
