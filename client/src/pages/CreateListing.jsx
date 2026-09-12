import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { api } from '../api/client.js';






function flattenTree(nodes, depth = 0, out = []) {
  for (const node of nodes) {
    out.push({ category_id: node.category_id, name: node.name, depth });
    flattenTree(node.children, depth + 1, out);
  }
  return out;
}

const CONDITIONS = ['NEW', 'LIKE_NEW', 'USED', 'REFURBISHED'];

export default function CreateListing() {
  const navigate = useNavigate();
  const [categories, setCategories] = useState([]);
  const [form, setForm] = useState({
    category_id: '',
    title: '',
    description: '',
    condition: 'USED',
    starting_price: '',
    bid_increment: '1.00',
    reserve_price: '',
    end_time: '',
  });
  
  
  
  
  const [attributeRows, setAttributeRows] = useState([{ key: '', value: '' }]);
  const [error, setError] = useState(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    let cancelled = false;
    api
      .get('/categories/tree')
      .then(({ categories: tree }) => {
        if (!cancelled) setCategories(flattenTree(tree));
      })
      .catch(() => {
        
      });
    return () => {
      cancelled = true;
    };
  }, []);

  function update(field) {
    return (e) => setForm((prev) => ({ ...prev, [field]: e.target.value }));
  }

  function updateAttributeRow(index, field) {
    return (e) => {
      const value = e.target.value;
      setAttributeRows((prev) => prev.map((row, i) => (i === index ? { ...row, [field]: value } : row)));
    };
  }

  function addAttributeRow() {
    setAttributeRows((prev) => [...prev, { key: '', value: '' }]);
  }

  function removeAttributeRow(index) {
    setAttributeRows((prev) => prev.filter((_, i) => i !== index));
  }

  
  
  
  
  function validate() {
    if (!form.category_id || !form.title || !form.starting_price || !form.bid_increment || !form.end_time) {
      return 'category, title, starting price, bid increment and end time are required.';
    }
    if (Number(form.starting_price) <= 0) return 'starting price must be greater than 0.';
    if (Number(form.bid_increment) <= 0) return 'bid increment must be greater than 0.';
    if (form.reserve_price && Number(form.reserve_price) < Number(form.starting_price)) {
      return 'reserve price cannot be below the starting price.';
    }
    if (new Date(form.end_time) <= new Date()) return 'end time must be in the future.';
    return null;
  }

  async function handleSubmit(e) {
    e.preventDefault();
    const validationError = validate();
    if (validationError) {
      setError(validationError);
      return;
    }

    setError(null);
    setSubmitting(true);
    try {
      const attributes = Object.fromEntries(
        attributeRows.filter((row) => row.key.trim()).map((row) => [row.key.trim(), row.value])
      );

      const { item } = await api.post('/items', {
        category_id: Number(form.category_id),
        title: form.title,
        description: form.description || undefined,
        condition: form.condition,
        attributes,
      });

      const { auction } = await api.post('/auctions', {
        item_id: item.item_id,
        starting_price: Number(form.starting_price),
        bid_increment: Number(form.bid_increment),
        reserve_price: form.reserve_price ? Number(form.reserve_price) : undefined,
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
      <form className="form" onSubmit={handleSubmit} style={{ maxWidth: 520 }}>
        <div className="field">
          <label htmlFor="category_id">Category</label>
          <select id="category_id" value={form.category_id} onChange={update('category_id')} required>
            <option value="">Select a category…</option>
            {categories.map((c) => (
              <option key={c.category_id} value={c.category_id}>
                {'—'.repeat(c.depth)} {c.name}
              </option>
            ))}
          </select>
        </div>

        <div className="field">
          <label htmlFor="title">Title</label>
          <input id="title" value={form.title} onChange={update('title')} required />
        </div>

        <div className="field">
          <label htmlFor="description">Description</label>
          <textarea id="description" rows={3} value={form.description} onChange={update('description')} />
        </div>

        <div className="field">
          <label htmlFor="condition">Condition</label>
          <select id="condition" value={form.condition} onChange={update('condition')}>
            {CONDITIONS.map((c) => (
              <option key={c} value={c}>
                {c.replace('_', ' ')}
              </option>
            ))}
          </select>
        </div>

        <div className="field">
          <label>Attributes</label>
          {attributeRows.map((row, i) => (
            <div className="field-row" key={i}>
              <input placeholder="key (e.g. ram)" value={row.key} onChange={updateAttributeRow(i, 'key')} />
              <input placeholder="value (e.g. 16GB)" value={row.value} onChange={updateAttributeRow(i, 'value')} />
              <button
                type="button"
                className="btn"
                onClick={() => removeAttributeRow(i)}
                disabled={attributeRows.length === 1}
              >
                Remove
              </button>
            </div>
          ))}
          <button type="button" className="btn" onClick={addAttributeRow} style={{ alignSelf: 'flex-start' }}>
            + Add attribute
          </button>
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
          <label htmlFor="reserve_price">Reserve price (optional)</label>
          <input
            id="reserve_price"
            type="number"
            step="0.01"
            min="0"
            value={form.reserve_price}
            onChange={update('reserve_price')}
          />
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
