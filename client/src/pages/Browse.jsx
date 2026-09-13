import { useEffect, useState, useMemo } from 'react';
import { useSearchParams } from 'react-router-dom';
import { api } from '../api/client.js';
import AuctionCard, { AuctionCardSkeletons } from '../components/AuctionCard.jsx';
import EmptyState from '../components/EmptyState.jsx';
import SqlNote from '../components/SqlNote.jsx';
import { indexCategories } from '../utils/categories.js';
import { pluralize } from '../utils/format.js';

const TABS = [
  { key: 'live', label: 'Live', empty: 'No live auctions' },
  { key: 'upcoming', label: 'Starting soon', empty: 'No upcoming auctions' },
];

const SORTS = [
  { key: 'soonest', label: (show) => (show === 'upcoming' ? 'Starting soonest' : 'Ending soonest') },
  { key: 'bids', label: () => 'Most bids', liveOnly: true },
  { key: 'high', label: () => 'Highest price' },
  { key: 'low', label: () => 'Lowest price' },
];

function compareAuctions(sort, show) {
  const time = (a) => new Date(show === 'upcoming' ? a.start_time : a.end_time).getTime();
  const price = (a) => Number(a.current_high_bid);

  switch (sort) {
    case 'bids':
      return (a, b) => b.bid_count - a.bid_count;
    case 'high':
      return (a, b) => price(b) - price(a);
    case 'low':
      return (a, b) => price(a) - price(b);
    default:
      return (a, b) => time(a) - time(b);
  }
}

// Counts are subtree totals: a category's own auctions plus every descendant's.
function annotateCounts(node, directCounts) {
  const ownCount = directCounts.get(node.category_id) || 0;
  const children = node.children.map((child) => annotateCounts(child, directCounts));
  const subtreeCount = ownCount + children.reduce((sum, c) => sum + c.subtreeCount, 0);
  return { ...node, children, subtreeCount };
}

function collectSubtreeIds(node) {
  return [node.category_id, ...node.children.flatMap(collectSubtreeIds)];
}

function findPath(nodes, id) {
  for (const node of nodes) {
    if (node.category_id === id) return [node];
    const rest = findPath(node.children, id);
    if (rest) return [node, ...rest];
  }
  return null;
}

function CategoryNode({ node, selectedId, expandedIds, onSelect, depth }) {
  const [expanded, setExpanded] = useState(depth < 1 || expandedIds.has(node.category_id));
  const hasChildren = node.children.length > 0;
  const isSelected = selectedId === node.category_id;

  return (
    <li>
      <div className="category-node-row">
        {hasChildren ? (
          <button
            type="button"
            onClick={() => setExpanded((e) => !e)}
            className="category-toggle"
            aria-expanded={expanded}
            aria-label={`${expanded ? 'Collapse' : 'Expand'} ${node.name}`}
          >
            {expanded ? '−' : '+'}
          </button>
        ) : (
          <span className="category-toggle" aria-hidden="true" />
        )}
        <button
          type="button"
          onClick={() => onSelect(node.category_id)}
          className={`category-name${isSelected ? ' selected' : ''}${node.subtreeCount === 0 ? ' is-empty' : ''}`}
          aria-pressed={isSelected}
        >
          <span className="category-label">{node.name}</span>
          <span className="count">{node.subtreeCount}</span>
        </button>
      </div>
      {hasChildren && expanded && (
        <ul>
          {node.children.map((child) => (
            <CategoryNode
              key={child.category_id}
              node={child}
              selectedId={selectedId}
              expandedIds={expandedIds}
              onSelect={onSelect}
              depth={depth + 1}
            />
          ))}
        </ul>
      )}
    </li>
  );
}

function TreeSkeleton() {
  return (
    <div className="tree-skeleton" aria-hidden="true">
      {[0, 1, 2, 3, 4, 5].map((i) => (
        <div key={i} className="skeleton skeleton-line" />
      ))}
    </div>
  );
}

export default function Browse() {
  const [searchParams, setSearchParams] = useSearchParams();
  const show = searchParams.get('show') === 'upcoming' ? 'upcoming' : 'live';
  const selectedId = Number(searchParams.get('category')) || null;

  const [tree, setTree] = useState([]);
  const [auctions, setAuctions] = useState({ live: [], upcoming: [] });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [sort, setSort] = useState('soonest');
  const [panelOpen, setPanelOpen] = useState(false);

  useEffect(() => {
    let cancelled = false;

    Promise.all([api.get('/categories/tree'), api.get('/auctions?status=ACTIVE'), api.get('/auctions?status=SCHEDULED')])
      .then(([treeData, liveData, upcomingData]) => {
        if (cancelled) return;
        setTree(treeData.categories);
        setAuctions({ live: liveData.auctions, upcoming: upcomingData.auctions });
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

  function updateParams(changes) {
    setSearchParams(
      (prev) => {
        const next = new URLSearchParams(prev);
        for (const [key, value] of Object.entries(changes)) {
          if (value == null) next.delete(key);
          else next.set(key, value);
        }
        return next;
      },
      { replace: true }
    );
  }

  const tabAuctions = auctions[show];

  const annotatedTree = useMemo(() => {
    const directCounts = new Map();
    for (const a of tabAuctions) {
      directCounts.set(a.category_id, (directCounts.get(a.category_id) || 0) + 1);
    }
    return tree.map((node) => annotateCounts(node, directCounts));
  }, [tree, tabAuctions]);

  const categories = useMemo(() => indexCategories(tree), [tree]);
  const selectedPath = useMemo(
    () => (selectedId ? findPath(annotatedTree, selectedId) || [] : []),
    [annotatedTree, selectedId]
  );
  const selected = selectedPath[selectedPath.length - 1] || null;
  const expandedIds = useMemo(() => new Set(selectedPath.map((n) => n.category_id)), [selectedPath]);

  const effectiveSort = show === 'upcoming' && sort === 'bids' ? 'soonest' : sort;

  const visibleAuctions = useMemo(() => {
    const ids = selected ? new Set(collectSubtreeIds(selected)) : null;
    return tabAuctions.filter((a) => !ids || ids.has(a.category_id)).sort(compareAuctions(effectiveSort, show));
  }, [tabAuctions, selected, effectiveSort, show]);

  function selectCategory(id) {
    updateParams({ category: id });
    setPanelOpen(false);
  }

  const selectedName = selected ? selected.name : 'All categories';
  const emptyText = TABS.find((t) => t.key === show).empty;

  return (
    <div>
      <header className="page-header">
        <h1 className="page-title">Browse</h1>
        <p className="page-caption">Five unrelated domains in one category tree, as deep as it needs to go.</p>
      </header>

      {error && <div className="form-error" role="alert">{error}</div>}

      <div className="two-col">
        <aside className="browse-aside">
          <button
            type="button"
            className="btn category-panel-toggle"
            aria-expanded={panelOpen}
            aria-controls="category-panel"
            onClick={() => setPanelOpen((o) => !o)}
          >
            <span>
              Category: <strong>{selectedName}</strong>
            </span>
            <span aria-hidden="true">{panelOpen ? '▴' : '▾'}</span>
          </button>
          <div id="category-panel" className={`category-panel${panelOpen ? ' open' : ''}`}>
            <nav className="category-tree card" aria-label="Categories">
              {loading && <TreeSkeleton />}
              {!loading && !error && annotatedTree.length === 0 && <EmptyState icon="🗂️">No categories yet.</EmptyState>}
              {annotatedTree.length > 0 && (
                <>
                  <button
                    type="button"
                    onClick={() => selectCategory(null)}
                    className={`category-name category-all${!selected ? ' selected' : ''}`}
                    aria-pressed={!selected}
                  >
                    <span className="category-label">All categories</span>
                    <span className="count">{tabAuctions.length}</span>
                  </button>
                  <ul>
                    {annotatedTree.map((node) => (
                      <CategoryNode
                        key={node.category_id}
                        node={node}
                        selectedId={selected?.category_id}
                        expandedIds={expandedIds}
                        onSelect={selectCategory}
                        depth={0}
                      />
                    ))}
                  </ul>
                </>
              )}
            </nav>
            <SqlNote view="get_category_tree()">
              WITH RECURSIVE cat_tree AS (… UNION ALL … JOIN cat_tree parent ON child.parent_id = parent.category_id)
            </SqlNote>
          </div>
        </aside>

        <section className="browse-results" aria-labelledby="results-title">
          <div className="results-toolbar">
            <div className="segmented" role="group" aria-label="Auction status">
              {TABS.map((tab) => (
                <button
                  key={tab.key}
                  type="button"
                  aria-pressed={show === tab.key}
                  onClick={() => updateParams({ show: tab.key === 'live' ? null : tab.key })}
                >
                  {tab.label} <span className="count">{loading ? '–' : auctions[tab.key].length}</span>
                </button>
              ))}
            </div>
            <div className="field sort-control">
              <label htmlFor="sort">Sort</label>
              <select id="sort" value={effectiveSort} onChange={(e) => setSort(e.target.value)}>
                {SORTS.filter((s) => !(s.liveOnly && show === 'upcoming')).map((s) => (
                  <option key={s.key} value={s.key}>
                    {s.label(show)}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div className="results-head">
            <h2 id="results-title" className="section-title">
              {selectedName}
            </h2>
            {!loading && (
              <span className="section-count">
                {visibleAuctions.length} {pluralize(visibleAuctions.length, 'auction')}
              </span>
            )}
          </div>

          {loading && <AuctionCardSkeletons count={3} />}
          {!loading && !error && visibleAuctions.length === 0 && (
            <EmptyState icon="🔨">
              {emptyText}
              {selected ? ` in ${selected.name}` : ''} right now.
            </EmptyState>
          )}
          {!loading && visibleAuctions.length > 0 && (
            <div className="grid">
              {visibleAuctions.map((a) => (
                <AuctionCard key={a.auction_id} auction={a} category={categories.get(a.category_id)} />
              ))}
            </div>
          )}
        </section>
      </div>
    </div>
  );
}
