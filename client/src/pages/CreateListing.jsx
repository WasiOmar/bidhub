import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { api } from '../api/client.js';

// Basic version for now: title/category/condition + starting price/increment/
// end time, creating the item then the auction in two calls. The category
// picker driven by the real tree, dynamic JSONB attribute rows, and reserve
// price are P3-04's job.
export default function CreateListing() {
  const navigate = useNavigate();
  const [form, setForm] = useState({
    category_id: '',
    title: '',
    condition: 'USED',
    starting_price: '',
    bid_increment: '1.00',
    end_time: '',
  });
  const [error, setError] = useState(null);
  const [submitting, setSubmitting] = useState(false);

  function update(field) {
    return (e) => setForm((prev) => ({ ...prev, [field]: e.target.value }));
  }

  async function handleSubmit(e) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const { item } = await api.post('/items', {
        category_id: Number(form.category_id),
        title: form.title,
        condition: form.condition,
      });

      const { auction } = await api.post('/auctions', {
        item_id: item.item_id,
        starting_price: Number(form.starting_price),
        bid_increment: Number(form.bid_increment),
        end_time: new Date(form.end_time).toISOString(),
      });

      navigate(`/auctions/${auction.auction_id}`);
    } catch (err) {
      setError(err.message || 'Could not create the listing.');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div>
      <h1 className="page-title">Sell an item</h1>
      {error && <div className="form-error">{error}</div>}
      <form className="form" onSubmit={handleSubmit}>
        <div className="field">
          <label htmlFor="category_id">Category ID</label>
          <input id="category_id" value={form.category_id} onChange={update('category_id')} required />
        </div>
        <div className="field">
          <label htmlFor="title">Title</label>
          <input id="title" value={form.title} onChange={update('title')} required />
        </div>
        <div className="field">
          <label htmlFor="condition">Condition</label>
          <select id="condition" value={form.condition} onChange={update('condition')}>
            <option value="NEW">New</option>
            <option value="LIKE_NEW">Like new</option>
            <option value="USED">Used</option>
            <option value="REFURBISHED">Refurbished</option>
          </select>
        </div>
        <div className="field-row">
          <div className="field">
            <label htmlFor="starting_price">Starting price</label>
            <input
              id="starting_price"
              type="number"
              step="0.01"
              min="0.01"
              value={form.starting_price}
              onChange={update('starting_price')}
              required
            />
          </div>
          <div className="field">
            <label htmlFor="bid_increment">Bid increment</label>
            <input
              id="bid_increment"
              type="number"
              step="0.01"
              min="0.01"
              value={form.bid_increment}
              onChange={update('bid_increment')}
              required
            />
          </div>
        </div>
        <div className="field">
          <label htmlFor="end_time">Auction end time</label>
          <input id="end_time" type="datetime-local" value={form.end_time} onChange={update('end_time')} required />
        </div>
        <button className="btn btn-primary" type="submit" disabled={submitting}>
          {submitting ? 'Publishing…' : 'Publish listing'}
        </button>
      </form>
    </div>
  );
}
