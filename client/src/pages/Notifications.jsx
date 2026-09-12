import { useEffect, useState } from 'react';
import { api } from '../api/client.js';
import Spinner from '../components/Spinner.jsx';
import Badge from '../components/Badge.jsx';
import EmptyState from '../components/EmptyState.jsx';
import { useToast } from '../context/ToastContext.jsx';

const TYPE_TONE = {
  OUTBID: 'outbid',
  WON: 'won',
  SOLD: 'won',
  AUCTION_CLOSED: 'closed',
};

export default function Notifications() {
  const { showToast } = useToast();
  const [notifications, setNotifications] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [markingIds, setMarkingIds] = useState(() => new Set());

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
    if (markingIds.has(id)) return;
    setMarkingIds((prev) => new Set(prev).add(id));
    try {
      await api.patch(`/notifications/${id}/read`);
      setNotifications((prev) => prev.map((n) => (n.notification_id === id ? { ...n, is_read: true } : n)));
      showToast('Marked as read.');
    } catch {
      showToast('Could not mark as read.', { tone: 'error' });
    } finally {
      setMarkingIds((prev) => {
        const next = new Set(prev);
        next.delete(id);
        return next;
      });
    }
  }

  return (
    <div>
      <h1 className="page-title">Notifications</h1>
      <p className="page-caption">
        Every row here was written by a database trigger, not by application code — see
        trg_outbid and trg_close_auction in db/02_triggers.sql.
      </p>

      {loading && <Spinner />}
      {error && <div className="form-error" role="alert">{error}</div>}
      {!loading && !error && notifications.length === 0 && (
        <EmptyState icon="🔔">No notifications yet.</EmptyState>
      )}

      {notifications.map((n) => (
        <div key={n.notification_id} className={`notification-item ${n.is_read ? '' : 'unread'}`}>
          <div>
            <Badge tone={TYPE_TONE[n.type] || 'closed'}>{n.type}</Badge>
            <div>{n.title}</div>
            <div className="page-caption caption-inline">
              {n.message}
            </div>
          </div>
          {!n.is_read && (
            <button
              className="btn"
              onClick={() => markRead(n.notification_id)}
              aria-label={`Mark "${n.title}" as read`}
              disabled={markingIds.has(n.notification_id)}
            >
              Mark read
            </button>
          )}
        </div>
      ))}
    </div>
  );
}
