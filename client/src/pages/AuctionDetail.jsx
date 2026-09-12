import { useEffect, useState, useCallback, useMemo } from 'react';
import { useParams, Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import { useToast } from '../context/ToastContext.jsx';
import { api, ApiError } from '../api/client.js';
import Spinner from '../components/Spinner.jsx';
import Badge from '../components/Badge.jsx';
import { formatMoney, formatTime, pluralize } from '../utils/format.js';

const POLL_MS = 5000;

const URGENT_MS = 5 * 60 * 1000;

function useCountdown(endTime) {
  const [remaining, setRemaining] = useState(() => new Date(endTime) - new Date());

  useEffect(() => {
    const timer = setInterval(() => setRemaining(new Date(endTime) - new Date()), 1000);
    return () => clearInterval(timer);
  }, [endTime]);

  if (remaining <= 0) return { text: 'Ended', urgent: false };

  const totalSeconds = Math.floor(remaining / 1000);
  const days = Math.floor(totalSeconds / 86400);
  const hours = Math.floor((totalSeconds % 86400) / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  const urgent = remaining <= URGENT_MS;
  if (days > 0) return { text: `${days}d ${hours}h ${minutes}m`, urgent };
  if (hours > 0) return { text: `${hours}h ${minutes}m ${seconds}s`, urgent };
  return { text: `${minutes}m ${seconds}s`, urgent };
}

function AttributesTable({ attributes }) {
  const entries = Object.entries(attributes || {});
  if (entries.length === 0) return null;

  return (
    <div className="table-scroll">
    <table>
      <tbody>
        {entries.map(([key, value]) => (
          <tr key={key}>
            <th className="attr-label">{key.replace(/_/g, ' ')}</th>
            <td>{String(value)}</td>
          </tr>
        ))}
      </tbody>
    </table>
    </div>
  );
}








function BidPanel({ auction, sellerId, onBidPlaced }) {
  const { user } = useAuth();
  const { showToast } = useToast();
  const [amount, setAmount] = useState('');
  const [error, setError] = useState(null);
  const [submitting, setSubmitting] = useState(false);

  const minNextBid = auction.bid_count === 0
    ? Number(auction.starting_price)
    : Number(auction.current_high_bid) + Number(auction.bid_increment);

  useEffect(() => {
    setAmount(minNextBid.toFixed(2));
    
  }, [auction.current_high_bid, auction.bid_count]);

  const isOwnListing = user && user.user_id === sellerId;
  const hasEnded = auction.status !== 'ACTIVE' || new Date(auction.end_time) <= new Date();

  async function handleSubmit(e) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await api.post(`/auctions/${auction.auction_id}/bids`, { amount: Number(amount) });
      showToast(`Bid of ${formatMoney(amount)} placed.`);
      onBidPlaced();
    } catch (err) {
      
      
      
      
      setError(err instanceof ApiError ? err.message : 'Could not place bid.');
    } finally {
      setSubmitting(false);
    }
  }

  if (!user) {
    return (
      <div className="empty-state">
        <Link to="/login">Log in</Link> to place a bid.
      </div>
    );
  }

  if (isOwnListing) {
    return <div className="empty-state">You cannot bid on your own listing.</div>;
  }

  if (hasEnded) {
    return <div className="empty-state">This auction has ended.</div>;
  }

  return (
    <form className="form form-narrow" onSubmit={handleSubmit}>
      {error && <div className="form-error" role="alert">{error}</div>}
      <div className="field">
        <label htmlFor="amount">Your bid (minimum {formatMoney(minNextBid)})</label>
        <input
          id="amount"
          type="number"
          step="0.01"
          min={minNextBid}
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          required
        />
      </div>
      <button className="btn btn-primary" type="submit" disabled={submitting}>
        {submitting ? 'Placing bid…' : 'Place bid'}
      </button>
    </form>
  );
}



function useLeaderboard(auctionId, refreshKey) {
  const [rows, setRows] = useState([]);

  const refresh = useCallback(async () => {
    try {
      const { leaderboard } = await api.get(`/auctions/${auctionId}/leaderboard`);
      setRows(leaderboard);
    } catch {
      
    }
  }, [auctionId]);

  useEffect(() => {
    refresh();
    const timer = setInterval(refresh, POLL_MS);
    return () => clearInterval(timer);
  }, [refresh, refreshKey]);

  return rows;
}

function LeaderboardTable({ rows }) {
  if (rows.length === 0) {
    return <div className="empty-state">No bids yet — be the first.</div>;
  }

  return (
    <div className="table-scroll">
    <table>
      <thead>
        <tr>
          <th>#</th>
          <th>Bidder</th>
          <th>Amount</th>
          <th>Placed</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => (
          
          
          
          <tr key={row.position} className={row.is_leading ? 'leading' : ''}>
            <td>{row.position}</td>
            <td>{row.bidder_name}</td>
            <td>{formatMoney(row.amount)}</td>
            <td>{formatTime(row.placed_at)}</td>
          </tr>
        ))}
      </tbody>
    </table>
    </div>
  );
}









function BidMomentum({ rows }) {
  const chronological = useMemo(
    () => [...rows].sort((a, b) => (new Date(a.placed_at) - new Date(b.placed_at)) || (Number(a.amount) - Number(b.amount))),
    [rows]
  );

  if (chronological.length < 2) {
    return <div className="empty-state">Needs at least two bids to show momentum.</div>;
  }

  const jumps = chronological.slice(1).map((row, i) => ({
    label: `#${i + 2}`,
    jump: Number(row.amount) - Number(chronological[i].amount),
  }));
  const max = Math.max(...jumps.map((j) => j.jump), 1);

  return (
    <div>
      {jumps.map((j) => (
        <div key={j.label} style={{ display: 'flex', alignItems: 'center', gap: 8, height: 24 }}>
          <span style={{ fontSize: '0.8rem', width: 28 }}>{j.label}</span>
          <svg width="70%" height="10" role="img" aria-label={`bid ${j.label} jump ${formatMoney(j.jump)}`}>
            <rect
              x="0"
              y="0"
              width={`${(j.jump / max) * 100}%`}
              height="10"
              rx="3"
              fill="var(--color-success)"
            />
          </svg>
          <span className="page-caption caption-inline">
            +{formatMoney(j.jump)}
          </span>
        </div>
      ))}
    </div>
  );
}

export default function AuctionDetail() {
  const { id } = useParams();
  const [auction, setAuction] = useState(null);
  const [item, setItem] = useState(null);
  const [breadcrumb, setBreadcrumb] = useState([]);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);
  const [refreshKey, setRefreshKey] = useState(0);

  
  
  
  
  
  const loadAuction = useCallback(async () => {
    try {
      const { auction: a } = await api.get(`/auctions/${id}`);
      setAuction(a);
      return a;
    } catch (err) {
      setError(err.message);
      return null;
    }
  }, [id]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);

    loadAuction()
      .then(async (a) => {
        if (cancelled || !a) return;
        const [{ item: itemRow }, { breadcrumb: rows }] = await Promise.all([
          api.get(`/items/${a.item_id}`),
          api.get(`/categories/${a.category_id}/breadcrumb`),
        ]);
        if (!cancelled) {
          setItem(itemRow);
          setBreadcrumb(rows);
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [id, loadAuction]);

  
  
  
  useEffect(() => {
    const timer = setInterval(() => {
      loadAuction();
    }, POLL_MS);
    return () => clearInterval(timer);
  }, [loadAuction]);

  const countdown = useCountdown(auction?.end_time || Date.now());
  const leaderboardRows = useLeaderboard(id, refreshKey);

  const attributesEntries = useMemo(() => Object.entries(item?.attributes || {}), [item]);

  if (loading) return <Spinner />;
  if (error) return <div className="form-error" role="alert">{error}</div>;
  if (!auction || !item) return <div className="empty-state">Auction not found.</div>;

  return (
    <div>
      {breadcrumb.length > 0 && (
        <p className="page-caption">
          {breadcrumb.map((c, idx) => (
            <span key={c.category_id}>
              {idx > 0 && ' > '}
              {c.name}
            </span>
          ))}
        </p>
      )}

      <h1 className="page-title">{auction.item_title}</h1>
      <Badge tone={auction.status.toLowerCase()}>{auction.status}</Badge>{' '}
      <span className={`page-caption countdown${countdown.urgent ? ' countdown-urgent' : ''}`} style={{ display: 'inline' }}>
        Ends in {countdown.text}
      </span>

      <div className="two-col mt-md">
        <div>
          {item.image_url && (
            <div className="auction-hero-media">
              <img src={item.image_url} alt={item.title} loading="lazy" onError={(e) => { e.currentTarget.parentElement.style.display = 'none'; }} />
            </div>
          )}
          <div className="card">
            <p className="caption-inline">
              Current high bid: <strong>{formatMoney(auction.current_high_bid)}</strong>
            </p>
            <p className="page-caption tight-top">
              {auction.bid_count} {pluralize(auction.bid_count, 'bid')} · starting price{' '}
              {formatMoney(auction.starting_price)} · increment {formatMoney(auction.bid_increment)}
            </p>
            <p className="page-caption tight-top">
              Sold by {item.seller_name} · condition: {item.condition}
            </p>
            {item.description && <p className="mb-0">{item.description}</p>}
          </div>

          {attributesEntries.length > 0 && (
            <div className="mt-md">
              <h3>Specifications</h3>
              {
}
              <AttributesTable attributes={item.attributes} />
            </div>
          )}

          <div className="mt-md">
            <h3>Leaderboard</h3>
            <LeaderboardTable rows={leaderboardRows} />
          </div>

          <div className="mt-md">
            <h3>Bid momentum</h3>
            <p className="page-caption">LAG(amount) OVER (PARTITION BY auction_id ORDER BY placed_at) — v_bid_momentum</p>
            <BidMomentum rows={leaderboardRows} />
          </div>
        </div>

        <div className="card">
          <h3 className="mt-0">Place a bid</h3>
          <BidPanel
            auction={auction}
            sellerId={item.seller_id}
            onBidPlaced={async () => {
              await loadAuction();
              setRefreshKey((k) => k + 1);
            }}
          />
        </div>
      </div>
    </div>
  );
}
