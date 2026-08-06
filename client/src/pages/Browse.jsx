import { useEffect, useState } from 'react';
import { api } from '../api/client.js';

// Basic shell for now: renders the category tree from GET /api/categories/tree
// (get_category_tree(), db/04_queries.sql — a recursive CTE, arbitrary depth).
// Selecting a node to filter the auction grid, and subtree item counts, are
// P3-04's job — this page proves the tree itself renders correctly first.
function CategoryNode({ node }) {
  return (
    <li>
      <button type="button">{node.name}</button>
      {node.children.length > 0 && (
        <ul>
          {node.children.map((child) => (
            <CategoryNode key={child.category_id} node={child} />
          ))}
        </ul>
      )}
    </li>
  );
}

export default function Browse() {
  const [tree, setTree] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;

    api
      .get('/categories/tree')
      .then((data) => {
        if (!cancelled) setTree(data.categories || []);
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
      <h1 className="page-title">Browse categories</h1>
      <div className="two-col">
        <nav className="category-tree card">
          {loading && <div className="empty-state">Loading…</div>}
          {error && <div className="form-error">{error}</div>}
          {!loading && !error && tree.length === 0 && <div className="empty-state">No categories yet.</div>}
          {tree.length > 0 && (
            <ul>
              {tree.map((node) => (
                <CategoryNode key={node.category_id} node={node} />
              ))}
            </ul>
          )}
        </nav>
        <div className="empty-state">Select a category to filter active auctions.</div>
      </div>
    </div>
  );
}
