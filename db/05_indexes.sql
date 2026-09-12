-- =============================================================================
-- db/05_indexes.sql  ·  BidHub  ·  Owner: P2 (Procedural SQL & Performance)
--
-- Technique 09 — COMPOSITE INDEX, plus the partial, B-tree and GIN indexes that
-- back every other hot query path. Each index is documented with the exact query
-- it exists for. The measured EXPLAIN (ANALYZE, BUFFERS) before/after for every
-- index below lives in docs/performance.md, produced by db/tests/benchmark.sql.
--
-- PK and UNIQUE indexes come free with db/01_schema.sql; this file only adds the
-- secondary indexes. Idempotent: each index is dropped and recreated, so the
-- definition in this file is always the one that is live.
-- Run order: 01 → 02 → 03 → 04 → 05 → 06 → 07.
-- =============================================================================

-- pg_trgm provides gin_trgm_ops, which lets a GIN index answer ILIKE '%word%'.
-- Ships with the postgres:16 image (contrib); CREATE EXTENSION is idempotent.
CREATE EXTENSION IF NOT EXISTS pg_trgm;


-- -----------------------------------------------------------------------------
-- 1. idx_bids_auction_amount — COMPOSITE (auction_id, amount DESC)   [technique 09]
--
-- Makes "top bid for auction N" an index-only sorted scan instead of a full
-- table read on every page load. Queries it serves:
--   * place_bid()                 MAX(amount) WHERE auction_id = N   (every bid)
--   * GET /api/auctions[/:id]     LATERAL MAX(amount) / COUNT(*) per auction
--   * trg_outbid, trg_close_auction, award_winner
--                                 WHERE auction_id = N ORDER BY amount DESC ... LIMIT 1
--   * get_leaderboard()           WHERE auction_id = N
-- Column order matters: auction_id is the equality predicate so it must lead;
-- amount DESC then stores each auction's bids already sorted highest-first, so
-- MAX() is "read the first entry" and never a sort. The reverse order
-- (amount, auction_id) would be useless for all of the above.
-- It also covers fk_bids_auction, so ON DELETE CASCADE from auctions finds the
-- child bids without a sequential scan.
-- -----------------------------------------------------------------------------
DROP INDEX IF EXISTS idx_bids_auction_amount;
CREATE INDEX idx_bids_auction_amount
    ON bids (auction_id, amount DESC);
COMMENT ON INDEX idx_bids_auction_amount IS
    'Composite (technique 09): top bid / bid count per auction without reading the whole bids table.';


-- -----------------------------------------------------------------------------
-- 2. idx_auctions_active_end — PARTIAL (end_time) WHERE status = 'ACTIVE'
--
-- The index stays small because only live auctions are in it, and that is the
-- query the auction-close job and the homepage both run:
--   * close_expired_auctions()  cursor: WHERE end_time < now() AND status = 'ACTIVE' ORDER BY end_time
--   * GET /api/auctions?status=ACTIVE                                  ORDER BY end_time
-- CLOSED / CANCELLED auctions are the vast majority of the table over time and
-- are never looked up by end_time, so indexing them would be pure overhead.
-- The planner only uses a partial index when the query's WHERE implies the
-- index predicate — both queries above say status = 'ACTIVE' literally.
-- -----------------------------------------------------------------------------
DROP INDEX IF EXISTS idx_auctions_active_end;
CREATE INDEX idx_auctions_active_end
    ON auctions (end_time)
    WHERE status = 'ACTIVE';
COMMENT ON INDEX idx_auctions_active_end IS
    'Partial: live auctions ordered by end_time, for the close job cursor and the homepage grid.';


-- -----------------------------------------------------------------------------
-- 3. Foreign-key and lookup indexes. PostgreSQL does NOT index the referencing
--    side of a foreign key automatically, so each of these is a join / filter
--    column that would otherwise force a sequential scan.
-- -----------------------------------------------------------------------------

-- GET /api/items?category=N  →  category_id IN (SELECT ... FROM get_category_tree(N))
DROP INDEX IF EXISTS idx_items_category;
CREATE INDEX idx_items_category
    ON items (category_id);
COMMENT ON INDEX idx_items_category IS
    'Items in a category subtree (catalog browse); also covers fk_items_category.';

-- GET /api/items?seller=N, and the seller's own listings page.
DROP INDEX IF EXISTS idx_items_seller;
CREATE INDEX idx_items_seller
    ON items (seller_id);
COMMENT ON INDEX idx_items_seller IS
    'Items listed by one seller; also covers fk_items_seller.';

-- GET /api/me/bids  →  WHERE bidder_id = $1 ORDER BY placed_at DESC.
-- placed_at DESC in the index means the rows come out already in display order,
-- so there is no sort step.
DROP INDEX IF EXISTS idx_bids_bidder_placed;
CREATE INDEX idx_bids_bidder_placed
    ON bids (bidder_id, placed_at DESC);
COMMENT ON INDEX idx_bids_bidder_placed IS
    'A user''s bid history newest-first (My Bids page); also covers fk_bids_bidder.';

-- Unread notifications for one user: WHERE user_id = $1 AND is_read = false.
-- PARTIAL, because nearly every notification is eventually read. Only the unread
-- tail is indexed, so the index stays a fraction of the table's size.
-- NOTE: the current GET /api/notifications route filters on user_id alone
-- (no is_read predicate), so it cannot use this index — see docs/performance.md.
DROP INDEX IF EXISTS idx_notifications_user_unread;
CREATE INDEX idx_notifications_user_unread
    ON notifications (user_id)
    WHERE is_read = false;
COMMENT ON INDEX idx_notifications_user_unread IS
    'Partial: a user''s unread notifications only (the bell count).';

-- The recursive step of get_category_tree(), get_category_item_counts():
--   JOIN categories child ON child.parent_id = parent.category_id
-- Each recursion level looks up "children of these parents"; without this index
-- every level re-reads the whole categories table.
DROP INDEX IF EXISTS idx_categories_parent;
CREATE INDEX idx_categories_parent
    ON categories (parent_id);
COMMENT ON INDEX idx_categories_parent IS
    'Children of a category: the join in every recursive CTE step; also covers fk_categories_parent.';


-- -----------------------------------------------------------------------------
-- 4. GIN indexes — for values a B-tree cannot search inside.
-- -----------------------------------------------------------------------------

-- JSONB containment: attributes @> '{"brand":"Fender"}'. items.attributes is what
-- keeps the platform domain-agnostic (a laptop's RAM, a painting's medium), so it
-- has to be searchable without a sequential scan. jsonb_path_ops, not the
-- default jsonb_ops: it supports only @> (the one operator we need) and in
-- exchange produces a smaller and faster index.
DROP INDEX IF EXISTS idx_items_attributes;
CREATE INDEX idx_items_attributes
    ON items USING GIN (attributes jsonb_path_ops);
COMMENT ON INDEX idx_items_attributes IS
    'GIN (jsonb_path_ops): attribute containment search, e.g. attributes @> ''{"brand":"Fender"}''.';

-- Keyword search: GET /api/items?q=word  →  title ILIKE '%word%'.
-- A B-tree cannot help with a leading wildcard; a trigram index splits each
-- title into 3-character chunks and can find candidate rows for any substring.
DROP INDEX IF EXISTS idx_items_title_trgm;
CREATE INDEX idx_items_title_trgm
    ON items USING GIN (title gin_trgm_ops);
COMMENT ON INDEX idx_items_title_trgm IS
    'GIN trigram: substring keyword search on item titles (ILIKE ''%word%'').';


-- Refresh planner statistics so the new indexes are costed on real numbers.
ANALYZE;
