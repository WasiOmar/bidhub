import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../api/client.js';
import Spinner from '../components/Spinner.jsx';
import Badge from '../components/Badge.jsx';
import EmptyState from '../components/EmptyState.jsx';
import { formatMoney, formatDateTime } from '../utils/format.js';






function statusFor(bid, currentHighByAuction) {
  if (bid.won) return { label: 'Won', tone: 'won' };
  if (bid.auction_status === 'CLOSED') return { label: 'Lost', tone: 'closed' };

  const currentHigh = currentHighByAuction.get(bid.auction_id);
  if (currentHigh !== undefined && Number(bid.amount) < currentHigh) {
    return { label: 'Outbid', tone: 'outbid' };
  }
  return { label: 'Leading', tone: 'active' };
}

export default function MyBids() {
  const [bids, setBids] = useState([]);
  const [currentHighByAuction, setCurrentHighByAuction] = useState(new Map());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;

    api
      .get('/me/bids')
      .then(async ({ bids: rows }) => {
        if (cancelled) return;
        setBids(rows);

        const activeAuctionIds = [...new Set(rows.filter((b) => b.auction_status === 'ACTIVE').map((b) => b.auction_id))];
        const details = await Promise.all(
          activeAuctionIds.map((auctionId) =>
            api.get(`/auctions/${auctionId}`).then(({ auction }) => [auctionId, Number(auction.current_high_bid)])
          )
        );
        if (!cancelled) setCurrentHighByAuction(new Map(details));
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

      {loading && <Spinner />}
      {error && <div className="form-error" role="alert">{error}</div>}
      {!loading && !error && bids.length === 0 && <EmptyState icon="🏷️">You haven't bid on anything yet.</EmptyState>}

      {bids.length > 0 && (
        <div className="table-scroll">
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
              const status = statusFor(bid, currentHighByAuction);
              return (
                <tr key={bid.bid_id}>
                  <td>
                    <Link to={`/auctions/${bid.auction_id}`}>{bid.item_title}</Link>
                  </td>
                  <td>{formatMoney(bid.amount)}</td>
                  <td>
                    <Badge tone={status.tone}>{status.label}</Badge>
                  </td>
                  <td>{formatDateTime(bid.placed_at)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
        </div>
      )}
    </div>
  );
}
