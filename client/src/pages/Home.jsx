import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../api/client.js';
import AuctionCard, { AuctionCardSkeletons } from '../components/AuctionCard.jsx';
import EmptyState from '../components/EmptyState.jsx';
import { indexCategories } from '../utils/categories.js';
import { pluralize } from '../utils/format.js';

const RECENTLY_SOLD = 4;

const byTime = (key, direction = 1) => (a, b) => direction * (new Date(a[key]) - new Date(b[key]));

function AuctionSection({ id, title, description, auctions, categories, empty, emptyIcon, seeAll }) {
  return (
    <section className="home-section" aria-labelledby={id}>
      <div className="section-head">
        <div>
          <h2 id={id} className="section-title">
            {title} <span className="section-count">{auctions.length}</span>
          </h2>
          <p className="card-desc">{description}</p>
        </div>
        {seeAll && auctions.length > 0 && (
          <Link to={seeAll} className="section-link">
            See all →
          </Link>
        )}
      </div>
      {auctions.length === 0 ? (
        <EmptyState icon={emptyIcon}>{empty}</EmptyState>
      ) : (
        <div className="grid">
          {auctions.map((a) => (
            <AuctionCard key={a.auction_id} auction={a} category={categories.get(a.category_id)} />
          ))}
        </div>
      )}
    </section>
  );
}

export default function Home() {
  const [data, setData] = useState({ live: [], upcoming: [], sold: [], tree: [] });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;

    Promise.all([
      api.get('/auctions?status=ACTIVE'),
      api.get('/auctions?status=SCHEDULED'),
      api.get('/auctions?status=CLOSED'),
      api.get('/categories/tree'),
    ])
      .then(([live, upcoming, sold, tree]) => {
        if (cancelled) return;
        setData({
          live: live.auctions,
          upcoming: [...upcoming.auctions].sort(byTime('start_time')),
          sold: [...sold.auctions].sort(byTime('end_time', -1)).slice(0, RECENTLY_SOLD),
          tree: tree.categories,
        });
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

  const categories = useMemo(() => indexCategories(data.tree), [data.tree]);
  const liveBids = data.live.reduce((sum, a) => sum + a.bid_count, 0);

  return (
    <div>
      <header className="home-hero">
        <div>
          <h1 className="page-title">Auctions</h1>
          <p className="page-caption">Any category, any domain — electronics, art, vehicles, instruments, books.</p>
          {!loading && !error && (
            <ul className="hero-stats">
              <li>
                <strong>{data.live.length}</strong> live now
              </li>
              <li>
                <strong>{data.upcoming.length}</strong> starting soon
              </li>
              <li>
                <strong>{liveBids}</strong> {pluralize(liveBids, 'bid')} on live auctions
              </li>
            </ul>
          )}
        </div>
        <Link to="/browse" className="btn btn-primary">
          Browse categories
        </Link>
      </header>

      {error && <div className="form-error" role="alert">{error}</div>}

      {loading && <AuctionCardSkeletons />}

      {!loading && !error && (
        <>
          <AuctionSection
            id="ending-soon"
            title="Ending soonest"
            description="Live now. Place a bid before the clock runs out."
            auctions={data.live}
            categories={categories}
            empty="No live auctions right now. Check back soon."
            emptyIcon="🔨"
            seeAll="/browse"
          />
          <AuctionSection
            id="starting-soon"
            title="Starting soon"
            description="Scheduled auctions that open for bids shortly."
            auctions={data.upcoming}
            categories={categories}
            empty="Nothing scheduled yet."
            emptyIcon="🗓️"
            seeAll="/browse?show=upcoming"
          />
          <AuctionSection
            id="recently-sold"
            title="Recently sold"
            description="The latest auctions to close, with their winning bids."
            auctions={data.sold}
            categories={categories}
            empty="No auctions have closed yet."
            emptyIcon="🏁"
          />
        </>
      )}
    </div>
  );
}
