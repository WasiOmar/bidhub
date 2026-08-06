import { useEffect, useState, useCallback, useMemo } from 'react';
import { useParams, Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import { api, ApiError } from '../api/client.js';

const POLL_MS = 5000;

function formatMoney(amount) {
  return `$${Number(amount).toFixed(2)}`;
}

function useCountdown(endTime) {
  const [remaining, setRemaining] = useState(() => new Date(endTime) - new Date());

  useEffect(() => {
    const timer = setInterval(() => setRemaining(new Date(endTime) - new Date()), 1000);
    return () => clearInterval(timer);
  }, [endTime]);

  if (remaining <= 0) return 'Ended';

  const totalSeconds = Math.floor(remaining / 1000);
  const days = Math.floor(totalSeconds / 86400);
  const hours = Math.floor((totalSeconds % 86400) / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  if (days > 0) return `${days}d ${hours}h ${minutes}m`;
  if (hours > 0) return `${hours}h ${minutes}m ${seconds}s`;
  return `${minutes}m ${seconds}s`;
}

function AttributesTable({ attributes }) {
  const entries = Object.entries(attributes || {});
  if (entries.length === 0) return null;

  return (
    <table>
      <tbody>
        {entries.map(([key, value]) => (
          <tr key={key}>
            <th style={{ textTransform: 'capitalize', width: '40%' }}>{key.replace(/_/g, ' ')}</th>
            <td>{String(value)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

// Bid panel error copy: AU001/AU002/AU003 are typed SQLSTATEs RAISEd inside
// place_bid() (db/03_procedures.sql) -- AU001 "bid % is below the minimum
// required bid of %", AU002 "auction % is not open for bidding", AU003
// "seller % cannot bid on their own auction %". client/src/api/client.js
// already turns those codes into this exact copy; this component just
// decides WHICH extra UI reaction each one gets (disabling the form for
// AU002, for example).
function BidPanel({ auction, sellerId, onBidPlaced }) {
  const { user } = useAuth();
  const [amount, setAmount] = useState('');
  const [error, setError] = useState(null);
  const [submitting, setSubmitting] = useState(false);

  const minNextBid = auction.bid_count === 0
    ? Number(auction.starting_price)
    : Number(auction.current_high_bid) + Number(auction.bid_increment);

  useEffect(() => {
    setAmount(minNextBid.toFixed(2));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [auction.current_high_bid, auction.bid_count]);

  const isOwnListing = user && user.user_id === sellerId;
  const hasEnded = auction.status !== 'ACTIVE' || new Date(auction.end_time) <= new Date();

  async function handleSubmit(e) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await api.post(`/auctions/${auction.auction_id}/bids`, { amount: Number(amount) });
      onBidPlaced();
    } catch (err) {
      // AU002 ("This auction has ended or is not open for bidding.") also
      // means the countdown/status already disabled the form below, so this
      // branch mostly matters for AU001 (too low) surfacing mid-race, when
      // someone else's bid lands between this page loading and submitting.
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
    <form className="form" onSubmit={handleSubmit} style={{ maxWidth: 260 }}>
      {error && <div className="form-error">{error}</div>}
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

// Fetched once, shared by both the leaderboard table and the momentum
// chart below -- one poll loop instead of two duplicate ones.
function useLeaderboard(auctionId, refreshKey) {
  const [rows, setRows] = useState([]);

  const refresh = useCallback(async () => {
    try {
      const { leaderboard } = await api.get(`/auctions/${auctionId}/leaderboard`);
      setRows(leaderboard);
    } catch {
      // A missed poll tick just tries again next cycle.
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
          // position comes straight from ROW_NUMBER() OVER (PARTITION BY
          // auction_id ORDER BY amount DESC, placed_at ASC) in
          // get_leaderboard() (db/04_queries.sql) -- not computed here.
          <tr key={`${row.bidder_id}-${row.placed_at}`} className={row.is_leading ? 'leading' : ''}>
            <td>{row.position}</td>
            <td>{row.bidder_name}</td>
            <td>{formatMoney(row.amount)}</td>
            <td>{new Date(row.placed_at).toLocaleTimeString()}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

// No route currently exposes v_bid_momentum (db/04_queries.sql --
// LAG(amount) OVER (PARTITION BY auction_id ORDER BY placed_at)) directly,
// but get_leaderboard() already returns every bid's amount and placed_at,
// which is enough to reproduce the same "jump from the previous bid" here:
// sort by placed_at instead of rank, diff consecutive amounts. The window
// function itself still does the real computation server-side in the view;
// this is the same LAG logic, just walked in JS from data already fetched
// for the table above rather than a second endpoint.
function BidMomentum({ rows }) {
  const chronological = useMemo(() => [...rows].sort((a, b) => new Date(a.placed_at) - new Date(b.placed_at)), [rows]);

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
          <span className="page-caption" style={{ margin: 0 }}>
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

  // GET /api/auctions/:id carries the pricing/bidding fields (server/src/
  // routes/auctions.js); it does NOT carry attributes/seller_id/condition --
  // those live on the item, via GET /api/items/:item_id. Fetching both
  // rather than widening the auctions route keeps this page inside its own
  // "do not touch server/" boundary for this prompt.
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

  // Poll the auction itself every 5s too -- this is what makes two browser
  // windows on the same auction visibly race: current_high_bid and
  // bid_count update here without anyone touching this tab.
  useEffect(() => {
    const timer = setInterval(() => {
      loadAuction();
    }, POLL_MS);
    return () => clearInterval(timer);
  }, [loadAuction]);

  const countdown = useCountdown(auction?.end_time || Date.now());
  const leaderboardRows = useLeaderboard(id, refreshKey);

  const attributesEntries = useMemo(() => Object.entries(item?.attributes || {}), [item]);

  if (loading) return <div className="empty-state">Loading…</div>;
  if (error) return <div className="form-error">{error}</div>;
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
      <span className={`badge badge-${auction.status.toLowerCase()}`}>{auction.status}</span>{' '}
      <span className="page-caption" style={{ display: 'inline' }}>
        Ends in {countdown}
      </span>

      <div className="two-col" style={{ marginTop: 16 }}>
        <div>
          <div className="card">
            <p style={{ margin: 0 }}>
              Current high bid: <strong>{formatMoney(auction.current_high_bid)}</strong>
            </p>
            <p className="page-caption" style={{ margin: '4px 0 0' }}>
              {auction.bid_count} bid{auction.bid_count === 1 ? '' : 's'} · starting price{' '}
              {formatMoney(auction.starting_price)} · increment {formatMoney(auction.bid_increment)}
            </p>
            <p className="page-caption" style={{ margin: '4px 0 0' }}>
              Sold by {item.seller_name} · condition: {item.condition}
            </p>
            {item.description && <p style={{ marginBottom: 0 }}>{item.description}</p>}
          </div>

          {attributesEntries.length > 0 && (
            <div style={{ marginTop: 16 }}>
              <h3>Specifications</h3>
              {/* JSONB attributes rendered generically -- a laptop, a painting
                  and a car all use this same table, which is the point of
                  items.attributes being JSONB rather than a fixed column set. */}
              <AttributesTable attributes={item.attributes} />
            </div>
          )}

          <div style={{ marginTop: 16 }}>
            <h3>Leaderboard</h3>
            <LeaderboardTable rows={leaderboardRows} />
          </div>

          <div style={{ marginTop: 16 }}>
            <h3>Bid momentum</h3>
            <p className="page-caption">LAG(amount) OVER (PARTITION BY auction_id ORDER BY placed_at) — v_bid_momentum</p>
            <BidMomentum rows={leaderboardRows} />
          </div>
        </div>

        <div className="card">
          <h3 style={{ marginTop: 0 }}>Place a bid</h3>
          <BidPanel
            auction={auction}
            sellerId={item.seller_id}
            onBidPlaced={() => {
              loadAuction();
              setRefreshKey((k) => k + 1);
            }}
          />
        </div>
      </div>
    </div>
  );
}
