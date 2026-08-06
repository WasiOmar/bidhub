import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { api } from '../api/client.js';

function formatMoney(amount) {
  return `$${Number(amount).toFixed(2)}`;
}

// Basic detail view for now: item + current high bid, fetched once. The
// live bid panel (typed AU00x error copy), countdown, and 5s-polled
// leaderboard are P3-04's job — this page proves the underlying data loads
// correctly first.
export default function AuctionDetail() {
  const { id } = useParams();
  const [auction, setAuction] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);

    api
      .get(`/auctions/${id}`)
      .then(({ auction: a }) => {
        if (!cancelled) setAuction(a);
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
  }, [id]);

  if (loading) return <div className="empty-state">Loading…</div>;
  if (error) return <div className="form-error">{error}</div>;
  if (!auction) return <div className="empty-state">Auction not found.</div>;

  return (
    <div>
      <h1 className="page-title">{auction.item_title}</h1>
      <span className={`badge badge-${auction.status.toLowerCase()}`}>{auction.status}</span>

      <div className="card" style={{ marginTop: 16, maxWidth: 480 }}>
        <p>
          Current high bid: <strong>{formatMoney(auction.current_high_bid)}</strong>
        </p>
        <p>Starting price: {formatMoney(auction.starting_price)}</p>
        <p>Bid increment: {formatMoney(auction.bid_increment)}</p>
        <p>{auction.bid_count} bid(s) so far</p>
        <p>Ends: {new Date(auction.end_time).toLocaleString()}</p>
      </div>
    </div>
  );
}
