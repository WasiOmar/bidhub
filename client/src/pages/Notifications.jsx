import { useEffect, useState } from 'react';
import { api } from '../api/client.js';

// notifications.type is one of OUTBID | WON | SOLD | AUCTION_CLOSED
// (db/01_schema.sql enum) -- mapped onto the existing badge palette rather
// than inventing new colors per type.
const TYPE_BADGE = {
  OUTBID: 'badge-outbid',
  WON: 'badge-won',
  SOLD: 'badge-won',
  AUCTION_CLOSED: 'badge-closed',
};

export default function Notifications() {
  const [notifications, setNotifications] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;

    api
      .get('/notifications')
      .then(({ notifications: rows }) => {
        if (!cancelled) setNotifications(rows);
      })
      .catch((err) => {
        if (!cancelled) setError(err.message);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, []);

  async function markRead(id) {
    try {
      await api.patch(`/notifications/${id}/read`);
      setNotifications((prev) => prev.map((n) => (n.notification_id === id ? { ...n, is_read: true } : n)));
    } catch {
      // Leave the row as-is; the next full refresh will reconcile it.
    }
  }

  return (
    <div>
      <h1 className="page-title">Notifications</h1>
      <p className="page-caption">
        Every row here was written by a database trigger, not by application code — see
        trg_outbid and trg_close_auction in db/02_triggers.sql.
      </p>

      {loading && <div className="empty-state">Loading…</div>}
      {error && <div className="form-error">{error}</div>}
      {!loading && !error && notifications.length === 0 && (
        <div className="empty-state">No notifications yet.</div>
      )}

      {notifications.map((n) => (
        <div key={n.notification_id} className={`notification-item ${n.is_read ? '' : 'unread'}`}>
          <div>
            <span className={`badge ${TYPE_BADGE[n.type] || 'badge-closed'}`}>{n.type}</span>
            <div>{n.title}</div>
            <div className="page-caption" style={{ margin: 0 }}>
              {n.message}
            </div>
          </div>
          {!n.is_read && (
            <button className="btn" onClick={() => markRead(n.notification_id)}>
              Mark read
            </button>
          )}
        </div>
      ))}
    </div>
  );
}
