export function formatMoney(amount) {
  return `$${Number(amount).toFixed(2)}`;
}

export function formatDateTime(value) {
  return new Date(value).toLocaleString();
}

export function formatTime(value) {
  return new Date(value).toLocaleTimeString();
}
