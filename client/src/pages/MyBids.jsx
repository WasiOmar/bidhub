import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../api/client.js';

function formatMoney(amount) {
  return `$${Number(amount).toFixed(2)}`;
}

function statusFor(bid) {
  if (bid.won) return { label: 'Won', className: 'badge-won' };
  if (bid.auction_status === 'CLOSED') return { label: 'Lost', className: 'badge-closed' };
  return { label: 'Active', className: 'badge-active' };
}

export default function MyBids() {
  const [bids, setBids] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;

    api
      .get('/me/bids')
      .then(({ bids: rows }) => {
        if (!cancelled) setBids(rows);
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

  return (
    <div>
      <h1 className="page-title">My bids</h1>

      {loading && <div className="empty-state">Loading…</div>}
      {error && <div className="form-error">{error}</div>}
      {!loading && !error && bids.length === 0 && <div className="empty-state">You haven't bid on anything yet.</div>}

      {bids.length > 0 && (
        <table>
          <thead>
            <tr>
              <th>Item</th>
              <th>Your bid</th>
              <th>Status</th>
              <th>Placed</th>
            </tr>
          </thead>
          <tbody>
            {bids.map((bid) => {
              const status = statusFor(bid);
              return (
                <tr key={bid.bid_id}>
                  <td>
                    <Link to={`/auctions/${bid.auction_id}`}>{bid.item_title}</Link>
                  </td>
                  <td>{formatMoney(bid.amount)}</td>
                  <td>
                    <span className={`badge ${status.className}`}>{status.label}</span>
                  </td>
                  <td>{new Date(bid.placed_at).toLocaleString()}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
