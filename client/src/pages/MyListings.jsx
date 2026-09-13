import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../api/client.js';
import { AuctionCardSkeletons } from '../components/AuctionCard.jsx';
import EmptyState from '../components/EmptyState.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import { indexCategories } from '../utils/categories.js';
import { AuctionSection } from './Home.jsx';

const byStartAsc = (a, b) => new Date(a.start_time) - new Date(b.start_time);
const byEndDesc = (a, b) => new Date(b.end_time) - new Date(a.end_time);

export default function MyListings() {
  const { user } = useAuth();
  const isSeller = user?.role === 'SELLER';
  const [auctions, setAuctions] = useState([]);
  const [tree, setTree] = useState([]);
  const [loading, setLoading] = useState(isSeller);
  const [error, setError] = useState(null);

  useEffect(() => {
    if (!isSeller) return undefined;
    let cancelled = false;

    Promise.all([api.get('/auctions/mine'), api.get('/categories/tree')])
      .then(([mine, treeData]) => {
        if (cancelled) return;
        setAuctions(mine.auctions);
        setTree(treeData.categories);
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
  }, [isSeller]);

  const categories = useMemo(() => indexCategories(tree), [tree]);

  const groups = useMemo(
    () => ({
      live: auctions.filter((a) => a.status === 'ACTIVE'),
      upcoming: auctions.filter((a) => a.status === 'SCHEDULED').sort(byStartAsc),
      ended: auctions.filter((a) => a.status === 'CLOSED' || a.status === 'CANCELLED').sort(byEndDesc),
    }),
    [auctions]
  );

  if (!isSeller) {
    return (
      <div>
        <h1 className="page-title">My listings</h1>
        <EmptyState icon="🏪">Only seller accounts can list items.</EmptyState>
      </div>
    );
  }

  return (
    <div>
      <header className="page-header">
        <h1 className="page-title">My listings</h1>
        <p className="page-caption">Everything you've put up for auction, live, upcoming and finished.</p>
      </header>

      {error && <div className="form-error" role="alert">{error}</div>}

      {loading && <AuctionCardSkeletons />}

      {!loading && !error && auctions.length === 0 && (
        <EmptyState icon="🏪">
          You haven't listed anything yet. <Link to="/create-listing">Sell an item</Link>
        </EmptyState>
      )}

      {!loading && !error && auctions.length > 0 && (
        <>
          <AuctionSection
            id="my-live-title"
            title="Live"
            description="Taking bids right now."
            auctions={groups.live}
            categories={categories}
            empty="None of your listings are live."
            emptyIcon="⏱️"
          />
          <AuctionSection
            id="my-upcoming-title"
            title="Starting soon"
            description="Scheduled to open for bidding."
            auctions={groups.upcoming}
            categories={categories}
            empty="Nothing scheduled."
            emptyIcon="🗓️"
          />
          <AuctionSection
            id="my-ended-title"
            title="Ended"
            description="Closed auctions, most recent first."
            auctions={groups.ended}
            categories={categories}
            empty="No finished auctions yet."
            emptyIcon="🏁"
          />
        </>
      )}
    </div>
  );
}
