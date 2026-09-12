import { useEffect, useState, useMemo } from 'react';
import { api } from '../api/client.js';
import AuctionCard from '../components/AuctionCard.jsx';
import Spinner from '../components/Spinner.jsx';
import EmptyState from '../components/EmptyState.jsx';








function annotateCounts(node, directCounts) {
  const ownCount = directCounts.get(node.category_id) || 0;
  const children = node.children.map((child) => annotateCounts(child, directCounts));
  const subtreeCount = ownCount + children.reduce((sum, c) => sum + c.subtreeCount, 0);
  return { ...node, children, subtreeCount };
}

function collectSubtreeIds(node) {
  return [node.category_id, ...node.children.flatMap(collectSubtreeIds)];
}

function CategoryNode({ node, selectedId, onSelect, depth }) {
  const [expanded, setExpanded] = useState(depth < 1);
  const hasChildren = node.children.length > 0;

  return (
    <li>
      <div className="category-node-row">
        {hasChildren && (
          <button
            type="button"
            onClick={() => setExpanded((e) => !e)}
            className="category-toggle"
            aria-expanded={expanded}
            aria-label={`${expanded ? 'Collapse' : 'Expand'} ${node.name}`}
          >
            {expanded ? '−' : '+'}
          </button>
        )}
        <button
          type="button"
          onClick={() => onSelect(node)}
          className={selectedId === node.category_id ? 'selected' : ''}
          aria-pressed={selectedId === node.category_id}
        >
          {node.name} <span className="count">({node.subtreeCount})</span>
        </button>
      </div>
      {hasChildren && expanded && (
        <ul>
          {node.children.map((child) => (
            <CategoryNode
              key={child.category_id}
              node={child}
              selectedId={selectedId}
              onSelect={onSelect}
              depth={depth + 1}
            />
          ))}
        </ul>
      )}
    </li>
  );
}

export default function Browse() {
  const [tree, setTree] = useState([]);
  const [auctions, setAuctions] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [selected, setSelected] = useState(null);

  useEffect(() => {
    let cancelled = false;

    Promise.all([api.get('/categories/tree'), api.get('/items?limit=100'), api.get('/auctions?status=ACTIVE')])
      .then(([treeData, itemsData, auctionsData]) => {
        if (cancelled) return;

        const directCounts = new Map();
        for (const item of itemsData.items) {
          directCounts.set(item.category_id, (directCounts.get(item.category_id) || 0) + 1);
        }

        setTree(treeData.categories.map((node) => annotateCounts(node, directCounts)));
        setAuctions(auctionsData.auctions);
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

  
  
  
  const visibleAuctions = useMemo(() => {
    if (!selected) return auctions;
    const ids = new Set(collectSubtreeIds(selected));
    return auctions.filter((a) => ids.has(a.category_id));
  }, [auctions, selected]);

  return (
    <div>
      <h1 className="page-title">Browse categories</h1>
      <div className="two-col">
        <nav className="category-tree card">
          {loading && <Spinner />}
          {error && <div className="form-error" role="alert">{error}</div>}
          {!loading && !error && tree.length === 0 && <EmptyState icon="🗂️">No categories yet.</EmptyState>}
          {tree.length > 0 && (
            <>
              <button
                type="button"
                onClick={() => setSelected(null)}
                className={`mb-sm${!selected ? ' selected' : ''}`}
                aria-pressed={!selected}
              >
                All categories
              </button>
              <ul>
                {tree.map((node) => (
                  <CategoryNode
                    key={node.category_id}
                    node={node}
                    selectedId={selected?.category_id}
                    onSelect={setSelected}
                    depth={0}
                  />
                ))}
              </ul>
            </>
          )}
        </nav>

        <div>
          {!loading && visibleAuctions.length === 0 && (
            <EmptyState icon="🔨">No active auctions in this category.</EmptyState>
          )}
          {visibleAuctions.length > 0 && (
            <div className="grid">
              {visibleAuctions.map((a) => (
                <AuctionCard key={a.auction_id} auction={a} />
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
