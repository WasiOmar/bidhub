import { useEffect, useState, useCallback, useMemo } from 'react';
import { useParams, Link, useLocation } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import { useToast } from '../context/ToastContext.jsx';
import { api, ApiError } from '../api/client.js';
import Badge from '../components/Badge.jsx';
import EmptyState from '../components/EmptyState.jsx';
import SqlNote from '../components/SqlNote.jsx';
import useNow from '../hooks/useNow.js';
import { formatMoney, formatDateTime, formatRemaining, pluralize } from '../utils/format.js';

const POLL_MS = 5000;

const URGENT_MS = 5 * 60 * 1000;

const CONDITION_LABELS = {
  NEW: 'New',
  LIKE_NEW: 'Like new',
  USED: 'Used',
  REFURBISHED: 'Refurbished',
};

function formatWhen(value) {
  return new Date(value).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

function AuctionTiming({ auction, now }) {
  const start = new Date(auction.start_time).getTime();
  const end = new Date(auction.end_time).getTime();

  if (auction.status === 'CANCELLED') return <span>This auction was cancelled</span>;

  if (auction.status === 'CLOSED' || end <= now) {
    return <span>Ended {formatDateTime(auction.end_time)}</span>;
  }

  if (auction.status === 'SCHEDULED') {
    return start > now ? (
      <span>
        Starts in <strong>{formatRemaining(start - now)}</strong>
      </span>
    ) : (
      <span>Opening soon</span>
    );
  }

  return (
    <span className={end - now <= URGENT_MS ? 'countdown-urgent' : undefined}>
      Ends in <strong>{formatRemaining(end - now)}</strong>
      <span className="auction-time-sub"> · {formatDateTime(auction.end_time)}</span>
    </span>
  );
}

function BidPanel({ auction, sellerId, biddingOpen, onBidPlaced }) {
  const { user } = useAuth();
  const location = useLocation();
  const { showToast } = useToast();
  const [amount, setAmount] = useState('');
  const [error, setError] = useState(null);
  const [submitting, setSubmitting] = useState(false);

  const increment = Number(auction.bid_increment);
  const minNextBid = auction.bid_count === 0
    ? Number(auction.starting_price)
    : Number(auction.current_high_bid) + increment;

  useEffect(() => {
    setAmount(minNextBid.toFixed(2));

  }, [auction.current_high_bid, auction.bid_count]);

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

  if (auction.status === 'SCHEDULED') {
    return <p className="bid-note">Bidding opens when the auction starts.</p>;
  }

  if (!biddingOpen) {
    return <p className="bid-note">Bidding is closed for this auction.</p>;
  }

  if (!user) {
    return (
      <div className="bid-note">
        <p>Log in to place a bid on this item.</p>
        <Link className="btn btn-primary btn-block" to="/login" state={{ from: location }}>
          Log in to bid
        </Link>
      </div>
    );
  }

  if (user.user_id === sellerId) {
    return <p className="bid-note">This is your listing, so you can't bid on it.</p>;
  }

  const quickPicks = [minNextBid, minNextBid + increment, minNextBid + increment * 5].map((v) => v.toFixed(2));
  const numericAmount = Number(amount);

  return (
    <form className="bid-form" onSubmit={handleSubmit}>
      {error && <div className="form-error" role="alert">{error}</div>}
      <div className="field">
        <label htmlFor="amount">Your bid</label>
        <div className="money-input">
          <span aria-hidden="true">$</span>
          <input
            id="amount"
            type="number"
            inputMode="decimal"
            step="0.01"
            min={minNextBid}
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            aria-describedby="amount-hint"
            required
          />
        </div>
        <span id="amount-hint" className="field-hint">
          Minimum {formatMoney(minNextBid)}
        </span>
      </div>
      <div className="quick-picks" role="group" aria-label="Quick bid amounts">
        {quickPicks.map((value) => (
          <button
            key={value}
            type="button"
            className={`quick-pick${amount === value ? ' selected' : ''}`}
            aria-pressed={amount === value}
            onClick={() => setAmount(value)}
          >
            {formatMoney(value)}
          </button>
        ))}
      </div>
      <button className="btn btn-primary btn-block" type="submit" disabled={submitting}>
        {submitting ? 'Placing bid…' : `Place bid${numericAmount > 0 ? ` · ${formatMoney(numericAmount)}` : ''}`}
      </button>
    </form>
  );
}

function BidBox({ auction, item, leader, biddingOpen, onBidPlaced }) {
  const { user } = useAuth();
  const closed = auction.status === 'CLOSED';
  const hasBids = auction.bid_count > 0;
  const isYou = Boolean(user && leader && user.user_id === leader.bidder_id);

  let label = 'Current high bid';
  if (!hasBids) label = 'Starting price';
  else if (closed) label = 'Winning bid';

  let leaderLine = null;
  if (leader && hasBids) {
    if (closed) {
      leaderLine = (
        <>
          Won by <strong>{isYou ? 'you' : leader.bidder_name}</strong>
        </>
      );
    } else if (isYou) {
      leaderLine = <strong>You're the highest bidder</strong>;
    } else {
      leaderLine = (
        <>
          Leading: <strong>{leader.bidder_name}</strong>
        </>
      );
    }
  }

  return (
    <div className="card bid-box">
      <div className="bid-box-label">{label}</div>
      <div className="bid-box-price">{formatMoney(hasBids ? auction.current_high_bid : auction.starting_price)}</div>
      <div className="bid-box-meta">
        {auction.bid_count} {pluralize(auction.bid_count, 'bid')} · starting price {formatMoney(auction.starting_price)}{' '}
        · {formatMoney(auction.bid_increment)} increments
      </div>
      {leaderLine && (
        <div className={`bid-box-leader${isYou ? ' is-you' : ''}`}>
          <span aria-hidden="true">👑</span>
          <span>{leaderLine}</span>
        </div>
      )}
      <hr className="bid-box-divider" />
      <BidPanel auction={auction} sellerId={item.seller_id} biddingOpen={biddingOpen} onBidPlaced={onBidPlaced} />
    </div>
  );
}

function ItemDetails({ item }) {
  const specs = Object.entries(item.attributes || {});

  return (
    <section className="card card-stack" aria-labelledby="item-details-title">
      <h2 id="item-details-title" className="card-title">
        About this item
      </h2>
      {item.description && <p className="item-description">{item.description}</p>}
      <dl className="fact-grid">
        <div>
          <dt>Seller</dt>
          <dd>{item.seller_name}</dd>
        </div>
        <div>
          <dt>Condition</dt>
          <dd>{CONDITION_LABELS[item.condition] || item.condition}</dd>
        </div>
        <div>
          <dt>Category</dt>
          <dd>{item.category_name}</dd>
        </div>
      </dl>
      {specs.length > 0 && (
        <div>
          <h3 className="detail-subtitle">Specifications</h3>
          <dl className="spec-grid">
            {specs.map(([key, value]) => (
              <div key={key} className="spec-row">
                <dt>{key.replace(/_/g, ' ')}</dt>
                <dd>{String(value)}</dd>
              </div>
            ))}
          </dl>
        </div>
      )}
    </section>
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

function Leaderboard({ rows, closed }) {
  const top = Math.max(1, ...rows.map((r) => Number(r.amount)));

  return (
    <section className="card card-stack" aria-labelledby="leaderboard-title">
      <div>
        <h2 id="leaderboard-title" className="card-title">
          Leaderboard
        </h2>
        <p className="card-desc">Each bidder's highest bid{closed ? '.' : ', refreshed every 5 seconds.'}</p>
      </div>
      <SqlNote view="get_leaderboard()">ROW_NUMBER() OVER (ORDER BY amount DESC, placed_at ASC)</SqlNote>
      {rows.length === 0 ? (
        <EmptyState icon="🏷️">No bids yet. Be the first.</EmptyState>
      ) : (
        <ol className="leaderboard">
          {rows.map((row) => (
            <li key={row.bidder_id} className={`lb-row${row.is_leading ? ' lb-row-leading' : ''}`}>
              <span className={`lb-rank${row.position <= 3 ? ` lb-rank-${row.position}` : ''}`}>{row.position}</span>
              <div className="lb-main">
                <div className="lb-line">
                  <span className="lb-who">
                    <span className="lb-name">{row.bidder_name}</span>
                    {row.is_leading && <span className="lb-tag">{closed ? 'Winner' : 'Leading'}</span>}
                    <span className="lb-meta">{formatWhen(row.placed_at)}</span>
                  </span>
                  <span className="lb-value">{formatMoney(row.amount)}</span>
                </div>
                <div className="lb-track" aria-hidden="true">
                  <div className="lb-bar" style={{ width: `${(Number(row.amount) / top) * 100}%` }} />
                </div>
              </div>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}

// Built from the leaderboard (each bidder's best bid), not from v_bid_momentum:
// the API has no route for that view, so the demo shows the real LAG() in psql.
function BidMomentum({ rows }) {
  const chronological = useMemo(
    () => [...rows].sort((a, b) => (new Date(a.placed_at) - new Date(b.placed_at)) || (Number(a.amount) - Number(b.amount))),
    [rows]
  );

  const jumps = chronological.slice(1).map((row, i) => ({
    id: row.bidder_id,
    name: row.bidder_name,
    jump: Number(row.amount) - Number(chronological[i].amount),
  }));
  const max = Math.max(1, ...jumps.map((j) => j.jump));

  return (
    <section className="card card-stack" aria-labelledby="momentum-title">
      <div>
        <h2 id="momentum-title" className="card-title">
          Bid momentum
        </h2>
        <p className="card-desc">
          How much each bidder's best bid raised the price over the one before it, oldest first. Worked out in the
          browser from the leaderboard; the database version is the view below.
        </p>
      </div>
      <SqlNote view="v_bid_momentum">LAG(amount) OVER (PARTITION BY auction_id ORDER BY placed_at)</SqlNote>
      {jumps.length === 0 ? (
        <EmptyState icon="📈">Needs at least two bidders to show momentum.</EmptyState>
      ) : (
        <ol className="momentum-list">
          {jumps.map((j) => (
            <li key={j.id} className="momentum-row">
              <span className="momentum-name">{j.name}</span>
              <div className="momentum-track" aria-hidden="true">
                <div className="momentum-bar" style={{ width: `${(Math.max(0, j.jump) / max) * 100}%` }} />
              </div>
              <span className="momentum-value">
                {j.jump < 0 ? '−' : '+'}
                {formatMoney(Math.abs(j.jump))}
              </span>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}

function AuctionSkeleton() {
  return (
    <div aria-busy="true" aria-label="Loading auction">
      <div className="skeleton skeleton-text" />
      <div className="skeleton skeleton-title" />
      <div className="auction-layout">
        <div className="auction-main">
          <div className="card">
            <div className="skeleton skeleton-text" />
            <div className="skeleton skeleton-block" />
          </div>
        </div>
        <div className="card">
          <div className="skeleton skeleton-text" />
          <div className="skeleton skeleton-value" />
          <div className="skeleton skeleton-block skeleton-block-sm" />
        </div>
      </div>
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

  const now = useNow();
  const leaderboardRows = useLeaderboard(id, refreshKey);

  if (loading) return <AuctionSkeleton />;
  if (error) return <div className="form-error" role="alert">{error}</div>;
  if (!auction || !item) {
    return (
      <EmptyState icon="🔍">
        Auction not found. <Link to="/browse">Browse auctions</Link>
      </EmptyState>
    );
  }

  const closed = auction.status === 'CLOSED';
  const biddingOpen = auction.status === 'ACTIVE' && new Date(auction.end_time).getTime() > now;
  const leader = leaderboardRows.find((row) => row.is_leading);

  return (
    <div>
      {breadcrumb.length > 0 && (
        <nav className="breadcrumb" aria-label="Category">
          <ol>
            {breadcrumb.map((c, idx) => (
              <li key={c.category_id} aria-current={idx === breadcrumb.length - 1 ? 'page' : undefined}>
                {c.name}
              </li>
            ))}
          </ol>
        </nav>
      )}

      <header className="auction-header">
        <h1 className="page-title">{auction.item_title}</h1>
        <div className="auction-status">
          <Badge tone={auction.status.toLowerCase()}>{auction.status}</Badge>
          <AuctionTiming auction={auction} now={now} />
        </div>
      </header>

      <div className="auction-layout">
        <div className="auction-main">
          {item.image_url && (
            <div className="auction-hero-media">
              <img src={item.image_url} alt={item.title} loading="lazy" onError={(e) => { e.currentTarget.parentElement.style.display = 'none'; }} />
            </div>
          )}
          <ItemDetails item={item} />
          <Leaderboard rows={leaderboardRows} closed={closed} />
          <BidMomentum rows={leaderboardRows} />
        </div>

        <aside className="auction-aside" aria-label="Bidding">
          <BidBox
            auction={auction}
            item={item}
            leader={leader}
            biddingOpen={biddingOpen}
            onBidPlaced={async () => {
              await loadAuction();
              setRefreshKey((k) => k + 1);
            }}
          />
        </aside>
      </div>
    </div>
  );
}
