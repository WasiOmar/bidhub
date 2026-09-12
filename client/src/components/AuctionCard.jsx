import { Link } from 'react-router-dom';
import { formatMoney, formatDateTime } from '../utils/format.js';

export default function AuctionCard({ auction }) {
  return (
    <Link to={`/auctions/${auction.auction_id}`} className="card auction-card">
      <div className="auction-card-media">
        {auction.image_url ? (
          <img src={auction.image_url} alt="" loading="lazy" onError={(e) => { e.currentTarget.style.display = 'none'; }} />
        ) : (
          <span className="auction-card-media-placeholder" aria-hidden="true">📦</span>
        )}
      </div>
      <span className="title">{auction.item_title}</span>
      <span className="price">{formatMoney(auction.current_high_bid)}</span>
      <span className="meta">
        {auction.bid_count} bid{auction.bid_count === 1 ? '' : 's'}
        {auction.end_time && <> · ends {formatDateTime(auction.end_time)}</>}
      </span>
    </Link>
  );
}
