import { useEffect, useState, useMemo } from 'react';
import { api } from '../api/client.js';
import Spinner from '../components/Spinner.jsx';

function formatMoney(amount) {
  return `$${Number(amount).toFixed(2)}`;
}



function BarChart({ rows, labelKey, valueKey }) {
  const max = Math.max(1, ...rows.map((r) => Number(r[valueKey])));
  const rowHeight = 28;

  return (
    <svg width="100%" height={rows.length * rowHeight} role="img" aria-label="bar chart">
      {rows.map((row, i) => {
        const widthPct = (Number(row[valueKey]) / max) * 100;
        return (
          <g key={row[labelKey] + i} transform={`translate(0, ${i * rowHeight})`}>
            <text x="0" y="14" fontSize="12" fill="var(--color-text)">
              {row[labelKey]}
            </text>
            <rect x="0" y="18" width={`${widthPct}%`} height="6" rx="3" fill="var(--color-accent)" />
          </g>
        );
      })}
    </svg>
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

  
  
  
  
  
  const latestPerSeller = useMemo(() => {
    const bySeller = new Map();
    for (const row of sellerRevenue) {
      bySeller.set(row.seller_id, row); 
    }
    return Array.from(bySeller.values());
  }, [sellerRevenue]);

  if (loading) return <Spinner />;
  if (error) return <div className="form-error">{error}</div>;

  return (
    <div>
      <h1 className="page-title">Analytics</h1>

      <section style={{ marginBottom: 32 }}>
        <h2>Top bidders</h2>
        <p className="page-caption">RANK() OVER (ORDER BY total_bid_value DESC) — v_top_bidders</p>
        {topBidders.length === 0 ? (
          <div className="empty-state">No bids yet.</div>
        ) : (
          <>
            <BarChart rows={topBidders.slice(0, 10)} labelKey="full_name" valueKey="total_bid_value" />
            <table style={{ marginTop: 12 }}>
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
          </>
        )}
      </section>

      <section>
        <h2>Seller revenue</h2>
        <p className="page-caption">
          SUM(final_amount) OVER (PARTITION BY seller_id ORDER BY created_at ROWS UNBOUNDED PRECEDING) —
          v_seller_revenue
        </p>
        {latestPerSeller.length === 0 ? (
          <div className="empty-state">No completed sales yet.</div>
        ) : (
          <>
            <BarChart rows={latestPerSeller} labelKey="seller_name" valueKey="running_revenue" />
            <table style={{ marginTop: 12 }}>
              <thead>
                <tr>
                  <th>Seller</th>
                  <th>Running revenue</th>
                </tr>
              </thead>
              <tbody>
                {latestPerSeller.map((row) => (
                  <tr key={row.seller_id}>
                    <td>{row.seller_name}</td>
                    <td>{formatMoney(row.running_revenue)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}
      </section>
    </div>
  );
}
