import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../api/client.js';

function formatMoney(amount) {
  return `$${Number(amount).toFixed(2)}`;
}

export default function Home() {
  const [auctions, setAuctions] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;

    api
      .get('/auctions?status=ACTIVE')
      .then(({ auctions: rows }) => {
        if (!cancelled) setAuctions(rows);
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
      <h1 className="page-title">Active auctions</h1>
      <p className="page-caption">Any category, any domain — electronics, art, vehicles, instruments, books.</p>

      {loading && <div className="empty-state">Loading auctions…</div>}
      {error && <div className="form-error">{error}</div>}
      {!loading && !error && auctions.length === 0 && (
        <div className="empty-state">No active auctions right now. Check back soon.</div>
      )}

      <div className="grid">
        {auctions.map((a) => (
          <Link key={a.auction_id} to={`/auctions/${a.auction_id}`} className="card auction-card">
            <span className="title">{a.item_title}</span>
            <span className="price">{formatMoney(a.current_high_bid)}</span>
            <span className="meta">
              {a.bid_count} bid{a.bid_count === 1 ? '' : 's'} · ends {new Date(a.end_time).toLocaleString()}
            </span>
          </Link>
        ))}
      </div>
    </div>
  );
}
