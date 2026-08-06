import { useEffect, useState } from 'react';
import { api } from '../api/client.js';

function formatMoney(amount) {
  return `$${Number(amount).toFixed(2)}`;
}

// Basic tables for now, straight off v_top_bidders and v_seller_revenue
// (db/04_queries.sql — RANK() and a running-total window function). Charts
// and the momentum/category-leaderboard views are P3-04's job.
export default function Analytics() {
  const [topBidders, setTopBidders] = useState([]);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;

    api
      .get('/analytics/top-bidders')
      .then(({ top_bidders }) => {
        if (!cancelled) setTopBidders(top_bidders);
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
      <h1 className="page-title">Analytics</h1>
      <p className="page-caption">Top bidders — RANK() OVER (ORDER BY total_bid_value DESC), v_top_bidders.</p>

      {loading && <div className="empty-state">Loading…</div>}
      {error && <div className="form-error">{error}</div>}
      {!loading && !error && topBidders.length === 0 && <div className="empty-state">No bids yet.</div>}

      {topBidders.length > 0 && (
        <table>
          <thead>
            <tr>
              <th>Rank</th>
              <th>Bidder</th>
              <th>Bids</th>
              <th>Total value</th>
            </tr>
          </thead>
          <tbody>
            {topBidders.map((row) => (
              <tr key={row.user_id}>
                <td>{row.rank}</td>
                <td>{row.full_name}</td>
                <td>{row.bid_count}</td>
                <td>{formatMoney(row.total_bid_value)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
