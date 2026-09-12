import { useEffect, useState } from 'react';
import { api } from '../api/client.js';
import AuctionCard from '../components/AuctionCard.jsx';
import Spinner from '../components/Spinner.jsx';
import EmptyState from '../components/EmptyState.jsx';

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

      {loading && <Spinner label="Loading auctions…" />}
      {error && <div className="form-error" role="alert">{error}</div>}
      {!loading && !error && auctions.length === 0 && (
        <EmptyState icon="🔨">No active auctions right now. Check back soon.</EmptyState>
      )}

      <div className="grid">
        {auctions.map((a) => (
          <AuctionCard key={a.auction_id} auction={a} />
        ))}
      </div>
    </div>
  );
}
