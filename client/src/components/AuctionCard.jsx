import { Link } from 'react-router-dom';
import useNow from '../hooks/useNow.js';
import { formatMoney, formatRemaining, formatShortDate, pluralize } from '../utils/format.js';

const URGENT_MS = 60 * 60 * 1000;

function cardStatus(auction, now) {
  const start = new Date(auction.start_time).getTime();
  const end = new Date(auction.end_time).getTime();
  const hasBids = auction.bid_count > 0;

  switch (auction.status) {
    case 'SCHEDULED':
      return {
        priceLabel: 'Starting at',
        time: start > now ? `Starts in ${formatRemaining(start - now, 2)}` : 'Opening soon',
      };
    case 'CLOSED':
      return {
        priceLabel: hasBids ? 'Sold for' : 'No bids · opened at',
        time: `Ended ${formatShortDate(auction.end_time)}`,
      };
    case 'CANCELLED':
      return { priceLabel: 'Starting price', time: 'Cancelled' };
    default:
      if (end <= now) return { priceLabel: hasBids ? 'Final bid' : 'Starting at', time: 'Ended' };
      return {
        priceLabel: hasBids ? 'Current bid' : 'Starting at',
        time: `Ends in ${formatRemaining(end - now, 2)}`,
        urgent: end - now <= URGENT_MS,
      };
  }
}

export default function AuctionCard({ auction, category }) {
  const now = useNow();
  const status = cardStatus(auction, now);

  return (
    <Link
      to={`/auctions/${auction.auction_id}`}
      className="card auction-card"
      style={category ? { '--cat-color': category.root.color } : undefined}
    >
      {auction.image_url && (
        <div className="auction-card-media">
          <img src={auction.image_url} alt="" loading="lazy" onError={(e) => { e.currentTarget.parentElement.style.display = 'none'; }} />
        </div>
      )}
      {category && (
        <span className="auction-card-banner">
          <span aria-hidden="true">{category.root.icon}</span>
          <span className="auction-card-category">{category.name}</span>
        </span>
      )}
      <span className="title">{auction.item_title}</span>
      <span className="auction-card-price">
        <span className="auction-card-label">{status.priceLabel}</span>
        <span className="price">{formatMoney(auction.current_high_bid)}</span>
      </span>
      <span className="auction-card-foot">
        <span>
          {auction.bid_count} {pluralize(auction.bid_count, 'bid')}
        </span>
        <span className={`auction-card-time${status.urgent ? ' countdown-urgent' : ''}`}>{status.time}</span>
      </span>
    </Link>
  );
}

export function AuctionCardSkeletons({ count = 4 }) {
  return (
    <div className="grid" aria-busy="true" aria-label="Loading auctions">
      {Array.from({ length: count }, (_, i) => (
        <div key={i} className="card auction-card-skeleton">
          <div className="skeleton skeleton-text" />
          <div className="skeleton skeleton-line" />
          <div className="skeleton skeleton-value" />
          <div className="skeleton skeleton-text" />
        </div>
      ))}
    </div>
  );
}
