import { useEffect, useState, useMemo } from 'react';
import { api } from '../api/client.js';
import EmptyState from '../components/EmptyState.jsx';
import { formatMoney, formatMoneyCompact, formatDateTime, pluralize } from '../utils/format.js';

const LEADERBOARD_PREVIEW = 10;

function SqlNote({ view, children }) {
  return (
    <div className="sql-note">
      <span className="sql-tag">SQL</span>
      <code className="sql-code">{children}</code>
      <span className="sql-view">{view}</span>
    </div>
  );
}

function StatTile({ label, value, title, sub }) {
  return (
    <div className="stat-tile">
      <div className="stat-label">{label}</div>
      <div className="stat-value" title={title}>
        {value}
      </div>
      {sub && <div className="stat-sub">{sub}</div>}
    </div>
  );
}

function Leaderboard({ rows }) {
  const [showAll, setShowAll] = useState(false);
  const max = Math.max(1, ...rows.map((r) => Number(r.total_bid_value)));

  const rankCounts = new Map();
  for (const row of rows) rankCounts.set(row.rank, (rankCounts.get(row.rank) || 0) + 1);

  const visible = showAll ? rows : rows.slice(0, LEADERBOARD_PREVIEW);

  return (
    <>
      <ol className="leaderboard">
        {visible.map((row) => {
          const rank = Number(row.rank);
          const tied = rankCounts.get(row.rank) > 1;
          const bids = Number(row.bid_count);
          const total = Number(row.total_bid_value);
          return (
            <li key={row.user_id} className="lb-row">
              <span
                className={`lb-rank${rank <= 3 ? ` lb-rank-${rank}` : ''}`}
                title={tied ? `Tied at rank ${rank}` : `Rank ${rank}`}
              >
                {tied ? `=${rank}` : rank}
              </span>
              <div className="lb-main">
                <div className="lb-line">
                  <span className="lb-who">
                    <span className="lb-name">{row.full_name}</span>
                    <span className="lb-meta">
                      {bids} {pluralize(bids, 'bid')}
                    </span>
                  </span>
                  <span className="lb-value">{formatMoney(total)}</span>
                </div>
                <div className="lb-track" aria-hidden="true">
                  <div className="lb-bar" style={{ width: `${(total / max) * 100}%` }} />
                </div>
              </div>
            </li>
          );
        })}
      </ol>
      {rows.length > LEADERBOARD_PREVIEW && (
        <button
          type="button"
          className="btn btn-ghost align-self-start"
          aria-expanded={showAll}
          onClick={() => setShowAll((v) => !v)}
        >
          {showAll ? `Show top ${LEADERBOARD_PREVIEW}` : `Show all ${rows.length} bidders`}
        </button>
      )}
    </>
  );
}

// Running revenue by sale order, not by time: seeded sales share timestamps,
// so a time axis would stack most points on one x position.
function RevenueSparkline({ seller }) {
  const { name, sales, total } = seller;
  const [active, setActive] = useState(null);
  const n = sales.length;
  const max = Math.max(1, total);

  const points = [
    { x: 0, y: 100 },
    ...sales.map((sale, i) => ({ x: ((i + 1) / n) * 100, y: 100 - (sale.running / max) * 100 })),
  ];
  const line = points.map((p, i) => `${i ? 'L' : 'M'}${p.x},${p.y}`).join(' ');
  const area = `${line} L100,100 L0,100 Z`;

  const shown = active ?? n - 1;
  const dot = points[shown + 1];
  const sale = sales[shown];

  function handlePointer(e) {
    const rect = e.currentTarget.getBoundingClientRect();
    const nearest = Math.round(((e.clientX - rect.left) / rect.width) * n);
    setActive(Math.min(n, Math.max(1, nearest)) - 1);
  }

  function handleKeyDown(e) {
    if (e.key === 'ArrowLeft') setActive((i) => Math.max(0, (i ?? n - 1) - 1));
    else if (e.key === 'ArrowRight') setActive((i) => Math.min(n - 1, (i ?? n - 1) + 1));
    else return;
    e.preventDefault();
  }

  return (
    <>
      <div
        className="spark-plot"
        role="img"
        tabIndex={0}
        aria-label={`${name}: running revenue reaches ${formatMoney(total)} over ${n} ${pluralize(n, 'sale')}`}
        onPointerMove={handlePointer}
        onPointerDown={handlePointer}
        onPointerLeave={() => setActive(null)}
        onFocus={() => setActive(n - 1)}
        onBlur={() => setActive(null)}
        onKeyDown={handleKeyDown}
      >
        <svg viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
          <path className="spark-area" d={area} />
          <path className="spark-line" d={line} />
        </svg>
        {active !== null && <span className="spark-cross" style={{ left: `${dot.x}%` }} />}
        <span className="spark-dot" style={{ left: `${dot.x}%`, top: `${dot.y}%` }} />
      </div>
      <div className="spark-readout">
        {active === null ? (
          'Running total after each sale'
        ) : (
          <>
            <strong>{formatMoney(sale.running)}</strong> after sale {active + 1} of {n} (+{formatMoney(sale.amount)})
          </>
        )}
      </div>
    </>
  );
}

function SellerRevenue({ sellers, grandTotal }) {
  return (
    <ul className="seller-list">
      {sellers.map((seller) => {
        const share = grandTotal > 0 ? (seller.total / grandTotal) * 100 : 0;
        return (
          <li key={seller.id} className="seller-row">
            <div className="seller-head">
              <span className="seller-name">{seller.name}</span>
              <span className="seller-total">{formatMoney(seller.total)}</span>
            </div>
            <div className="seller-sub">
              {seller.sales.length} {pluralize(seller.sales.length, 'sale')} ·{' '}
              {share > 0 && share < 1 ? '<1' : Math.round(share)}% of all revenue
            </div>
            <RevenueSparkline seller={seller} />
          </li>
        );
      })}
    </ul>
  );
}

function SalesTable({ sellers, count }) {
  return (
    <details className="data-details">
      <summary>View all {count} sales as a table</summary>
      <div className="table-scroll">
        <table className="compact-table">
          <thead>
            <tr>
              <th>Seller</th>
              <th className="num">Sale</th>
              <th className="num">Running revenue</th>
              <th>Recorded</th>
            </tr>
          </thead>
          <tbody>
            {sellers.flatMap((seller) =>
              seller.sales.map((sale) => (
                <tr key={sale.id}>
                  <td>{seller.name}</td>
                  <td className="num">{formatMoney(sale.amount)}</td>
                  <td className="num">{formatMoney(sale.running)}</td>
                  <td>{formatDateTime(sale.at)}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </details>
  );
}

function AnalyticsSkeleton() {
  return (
    <div aria-busy="true" aria-label="Loading analytics">
      <div className="stat-grid">
        {[0, 1, 2, 3].map((i) => (
          <div key={i} className="stat-tile">
            <div className="skeleton skeleton-text" />
            <div className="skeleton skeleton-value" />
          </div>
        ))}
      </div>
      <div className="analytics-grid">
        {[0, 1].map((i) => (
          <div key={i} className="card">
            <div className="skeleton skeleton-text" />
            <div className="skeleton skeleton-block" />
          </div>
        ))}
      </div>
    </div>
  );
}

export default function Analytics() {
  const [topBidders, setTopBidders] = useState([]);
  const [sellerRevenue, setSellerRevenue] = useState([]);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;

    Promise.all([api.get('/analytics/top-bidders'), api.get('/analytics/seller-revenue')])
      .then(([topBiddersData, revenueData]) => {
        if (cancelled) return;
        setTopBidders(topBiddersData.top_bidders);
        setSellerRevenue(revenueData.seller_revenue);
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

  const sellers = useMemo(() => {
    const bySeller = new Map();
    for (const row of sellerRevenue) {
      if (!bySeller.has(row.seller_id)) {
        bySeller.set(row.seller_id, { id: row.seller_id, name: row.seller_name, sales: [] });
      }
      bySeller.get(row.seller_id).sales.push({
        id: row.transaction_id,
        amount: Number(row.final_amount),
        running: Number(row.running_revenue),
        at: row.created_at,
      });
    }
    return Array.from(bySeller.values())
      .map((seller) => {
        // Running totals only grow, so sorting by them recovers the window's row order
        // even when several sales share a created_at.
        const sales = [...seller.sales].sort((a, b) => a.running - b.running);
        return { ...seller, sales, total: sales[sales.length - 1].running };
      })
      .sort((a, b) => b.total - a.total);
  }, [sellerRevenue]);

  const stats = useMemo(() => {
    const bidVolume = topBidders.reduce((sum, r) => sum + Number(r.total_bid_value), 0);
    const bidCount = topBidders.reduce((sum, r) => sum + Number(r.bid_count), 0);
    const revenue = sellers.reduce((sum, s) => sum + s.total, 0);
    const saleCount = sellerRevenue.length;
    return { bidVolume, bidCount, revenue, saleCount, avgSale: saleCount ? revenue / saleCount : 0 };
  }, [topBidders, sellers, sellerRevenue]);

  let body;
  if (loading) {
    body = <AnalyticsSkeleton />;
  } else if (error) {
    body = (
      <div className="form-error" role="alert">
        {error}
      </div>
    );
  } else {
    body = (
      <>
        <div className="stat-grid">
          <StatTile
            label="Bid volume"
            value={formatMoneyCompact(stats.bidVolume)}
            title={formatMoney(stats.bidVolume)}
            sub={`${stats.bidCount.toLocaleString('en-US')} ${pluralize(stats.bidCount, 'bid')} placed`}
          />
          <StatTile
            label="Bidders"
            value={topBidders.length}
            sub={topBidders.length ? `Leader: ${topBidders[0].full_name}` : 'No bids yet'}
          />
          <StatTile
            label="Seller revenue"
            value={formatMoneyCompact(stats.revenue)}
            title={formatMoney(stats.revenue)}
            sub={`${stats.saleCount} completed ${pluralize(stats.saleCount, 'sale')}`}
          />
          <StatTile
            label="Average sale"
            value={formatMoneyCompact(stats.avgSale)}
            title={formatMoney(stats.avgSale)}
            sub={`Across ${sellers.length} ${pluralize(sellers.length, 'seller')}`}
          />
        </div>

        <div className="analytics-grid">
          <section className="card analytics-card" aria-labelledby="top-bidders-title">
            <div>
              <h2 id="top-bidders-title" className="card-title">
                Top bidders
              </h2>
              <p className="card-desc">Ranked by the total value of every bid placed. Tied bidders share a rank.</p>
            </div>
            <SqlNote view="v_top_bidders">RANK() OVER (ORDER BY SUM(b.amount) DESC)</SqlNote>
            {topBidders.length === 0 ? (
              <EmptyState icon="📊">No bids yet.</EmptyState>
            ) : (
              <Leaderboard rows={topBidders} />
            )}
          </section>

          <section className="card analytics-card" aria-labelledby="seller-revenue-title">
            <div>
              <h2 id="seller-revenue-title" className="card-title">
                Seller revenue
              </h2>
              <p className="card-desc">Each seller's running total, growing with every completed sale.</p>
            </div>
            <SqlNote view="v_seller_revenue">
              SUM(final_amount) OVER (PARTITION BY seller_id ORDER BY created_at ROWS UNBOUNDED PRECEDING)
            </SqlNote>
            {sellers.length === 0 ? (
              <EmptyState icon="💰">No completed sales yet.</EmptyState>
            ) : (
              <>
                <SellerRevenue sellers={sellers} grandTotal={stats.revenue} />
                <SalesTable sellers={sellers} count={stats.saleCount} />
              </>
            )}
          </section>
        </div>
      </>
    );
  }

  return (
    <div>
      <header className="page-header">
        <h1 className="page-title">Analytics</h1>
        <p className="page-caption">
          Who is bidding the most and which sellers are earning, ranked and totalled inside PostgreSQL with window
          functions.
        </p>
      </header>
      {body}
    </div>
  );
}
