-- =============================================================================
-- db/04_queries.sql
-- BidHub — read-side SQL: leaderboard CTE, recursive category tree, and
-- window-function analytics.
-- Owner: Person 2 (Procedural SQL & Performance)
--
-- Three of the ten graded techniques live here, one per section below:
--   Technique 04 — CTE + ROW_NUMBER()   (get_leaderboard)
--   Technique 07 — RECURSIVE CTE        (get_category_tree, get_category_breadcrumb,
--                                         get_category_item_counts)
--   Technique 05 — WINDOW FUNCTIONS     (v_top_bidders, v_seller_revenue,
--                                         v_bid_momentum, v_category_leaderboard)
--
-- Depends on db/01_schema.sql and db/02_triggers.sql. Does NOT touch
-- db/03_procedures.sql — place_bid/award_winner/close_expired_auctions are
-- P2-01/P2-02's own file. Idempotent: every object is CREATE OR REPLACE.
-- =============================================================================

-- ===========================================================================
-- Technique 04 — CTE + ROW_NUMBER(): auction leaderboard
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- get_leaderboard(p_auction_id)
--
-- One CTE ranks every bid on the auction by amount (ties broken by whoever
-- got there first), joined out to the bidder's name and the item's title so
-- the caller gets one ready-to-render result set in a single round trip —
-- no N+1 lookups on the API side.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_leaderboard(p_auction_id INT)
RETURNS TABLE (
    position     INT,
    bidder_id    INT,
    bidder_name  VARCHAR(120),
    item_title   VARCHAR(200),
    amount       NUMERIC(12,2),
    placed_at    TIMESTAMPTZ,
    is_leading   BOOLEAN
)
LANGUAGE sql
STABLE
AS $$
    WITH ranked_bids AS (
        SELECT
            b.bidder_id,
            u.full_name AS bidder_name,
            i.title     AS item_title,
            b.amount,
            b.placed_at,
            -- Rank within THIS auction only (PARTITION BY auction_id), highest
            -- amount first; a tie goes to whoever placed_at earlier — the same
            -- tie-break place_bid()/trg_close_auction use to pick a winner, so
            -- position 1 here always agrees with who actually wins.
            ROW_NUMBER() OVER (
                PARTITION BY b.auction_id
                ORDER BY b.amount DESC, b.placed_at ASC
            ) AS position
        FROM bids b
        JOIN users u    ON u.user_id = b.bidder_id
        JOIN auctions a ON a.auction_id = b.auction_id
        JOIN items i    ON i.item_id = a.item_id
        WHERE b.auction_id = p_auction_id
    )
    SELECT
        position::INT,
        bidder_id,
        bidder_name,
        item_title,
        amount,
        placed_at,
        (position = 1) AS is_leading
    FROM ranked_bids
    ORDER BY position;
$$;

COMMENT ON FUNCTION get_leaderboard(INT) IS
    'CTE + ROW_NUMBER() OVER (PARTITION BY auction_id ORDER BY amount DESC, placed_at ASC): '
    'one ranked result set for the auction detail page, position 1 is always the current winner.';

-- ===========================================================================
-- Technique 07 — RECURSIVE CTE: category tree
--
-- Every recursive CTE below shares the same cycle guard: `depth < 20` caps
-- runaway recursion at a depth no real category tree should ever reach, and
-- the `path` check refuses to revisit a name already on the current branch.
-- categories.parent_id only blocks *direct* self-parenting at the schema
-- level (chk_categories_no_self_parent) — nothing stops a longer A -> B -> A
-- cycle at the data level, and WITH RECURSIVE has no built-in cycle
-- detection, so without this guard a bad row would recurse forever.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- get_category_tree(p_root_id)
--
-- p_root_id NULL -> the whole forest, every root category as depth 0.
-- p_root_id given -> just that category's subtree, depth 0 at the root.
-- ORDER BY path means the output is already in tree (depth-first) order --
-- exactly how a UI renders a collapsible tree, no client-side sorting needed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_category_tree(p_root_id INT DEFAULT NULL)
RETURNS TABLE (
    category_id INT,
    name        VARCHAR(100),
    slug        VARCHAR(120),
    parent_id   INT,
    depth       INT,
    path        TEXT[]
)
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE cat_tree AS (
        -- Anchor: the root(s) of the tree we're walking.
        SELECT
            c.category_id, c.name, c.slug, c.parent_id,
            0 AS depth,
            ARRAY[c.name]::TEXT[] AS path
        FROM categories c
        WHERE (p_root_id IS NULL AND c.parent_id IS NULL)
           OR (p_root_id IS NOT NULL AND c.category_id = p_root_id)

        UNION ALL

        -- Recursive step: join every category's direct children onto the
        -- rows already found, one level deeper each pass, until no more
        -- children match (arbitrary depth -- this is what makes the platform
        -- domain-agnostic instead of a fixed brand/line/variant hierarchy).
        SELECT
            child.category_id, child.name, child.slug, child.parent_id,
            parent.depth + 1,
            parent.path || child.name
        FROM categories child
        JOIN cat_tree parent ON child.parent_id = parent.category_id
        WHERE parent.depth < 20
          AND NOT (parent.path @> ARRAY[child.name])
    )
    SELECT category_id, name, slug, parent_id, depth, path
    FROM cat_tree
    ORDER BY path;
$$;

COMMENT ON FUNCTION get_category_tree(INT) IS
    'WITH RECURSIVE walking DOWN from a root (or every root when NULL): depth and path grow '
    'one level per pass, ORDER BY path yields tree order for free. Cycle-guarded (depth < 20, '
    'no repeated name in path).';

-- ---------------------------------------------------------------------------
-- get_category_breadcrumb(p_category_id)
--
-- Same recursive technique as get_category_tree, walking the opposite
-- direction: UP from a leaf to its root via parent_id instead of down via
-- children. Returned root-first (depth DESC) -- the order a breadcrumb reads.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_category_breadcrumb(p_category_id INT)
RETURNS TABLE (
    category_id INT,
    name        VARCHAR(100),
    slug        VARCHAR(120),
    parent_id   INT,
    depth       INT
)
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE ancestors AS (
        -- Anchor: the leaf category itself, depth 0.
        SELECT c.category_id, c.name, c.slug, c.parent_id, 0 AS depth
        FROM categories c
        WHERE c.category_id = p_category_id

        UNION ALL

        -- Recursive step: each row's parent, one level up per pass.
        SELECT p.category_id, p.name, p.slug, p.parent_id, a.depth + 1
        FROM categories p
        JOIN ancestors a ON p.category_id = a.parent_id
        WHERE a.depth < 20
    )
    SELECT category_id, name, slug, parent_id, depth
    FROM ancestors
    ORDER BY depth DESC;
$$;

COMMENT ON FUNCTION get_category_breadcrumb(INT) IS
    'WITH RECURSIVE walking UP from a leaf via parent_id to the root -- the same technique as '
    'get_category_tree, reversed. Root-first output, ready to render as Electronics > Computers > ....';

-- ---------------------------------------------------------------------------
-- get_category_item_counts()
--
-- A parent category must report the item count of its WHOLE subtree, not
-- just its direct children -- a roll-up. `descendants` first builds, for
-- every category, the set of every category at or below it (itself included
-- at depth 0, which is what lets direct_items and subtree_items share one
-- CTE); then items are joined onto that descendant set and counted per
-- ancestor.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_category_item_counts()
RETURNS TABLE (
    category_id   INT,
    name          VARCHAR(100),
    direct_items  BIGINT,
    subtree_items BIGINT
)
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE descendants AS (
        -- Anchor: every category is its own depth-0 "descendant" -- this is
        -- what makes direct_items (depth = 0 only) and subtree_items (every
        -- depth) both computable from one CTE.
        SELECT c.category_id AS ancestor_id, c.category_id AS descendant_id, 0 AS depth
        FROM categories c

        UNION ALL

        -- Recursive step: for every (ancestor, descendant) pair found so
        -- far, also pair the ancestor with that descendant's children --
        -- growing each ancestor's subtree by one more generation per pass.
        SELECT d.ancestor_id, child.category_id, d.depth + 1
        FROM descendants d
        JOIN categories child ON child.parent_id = d.descendant_id
        WHERE d.depth < 20
    )
    SELECT
        c.category_id,
        c.name,
        COUNT(i.item_id) FILTER (WHERE d.depth = 0)::BIGINT AS direct_items,
        COUNT(i.item_id)::BIGINT                             AS subtree_items
    FROM categories c
    JOIN descendants d  ON d.ancestor_id = c.category_id
    LEFT JOIN items i   ON i.category_id = d.descendant_id
    GROUP BY c.category_id, c.name
    ORDER BY c.category_id;
$$;

COMMENT ON FUNCTION get_category_item_counts() IS
    'Recursive roll-up: descendants pairs every category with its entire subtree (itself at '
    'depth 0), so a LEFT JOIN + COUNT against items gives each ancestor its whole-subtree item '
    'count, not just its direct children''s.';

-- ===========================================================================
-- Technique 05 — WINDOW FUNCTIONS: analytics
--
-- Every query below keeps one output row per input row (a bid, a
-- transaction) and adds a computed column alongside it. That is the whole
-- point of a window function versus GROUP BY: GROUP BY collapses many rows
-- into one per group and throws the individual rows away; a window function
-- computes the same kind of aggregate (a rank, a running sum, a lookback at
-- the previous row) WITHOUT collapsing anything, so the underlying rows are
-- still there to render in a table. v_top_bidders is the one exception below
-- worth noting: it aggregates first (GROUP BY user, one row per bidder is
-- exactly what "top bidders" means) and only THEN ranks that already-grouped
-- result with a window function, rather than a second self-join to work out
-- each bidder's placement.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- v_top_bidders — RANK() OVER (ORDER BY total_bid_value DESC)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_top_bidders AS
SELECT
    u.user_id,
    u.full_name,
    COUNT(b.bid_id)                          AS bid_count,
    SUM(b.amount)                            AS total_bid_value,
    RANK() OVER (ORDER BY SUM(b.amount) DESC) AS rank
FROM users u
JOIN bids b ON b.bidder_id = u.user_id
GROUP BY u.user_id, u.full_name;

COMMENT ON VIEW v_top_bidders IS
    'One row per bidder (GROUP BY, since "top bidders" IS one row per person) with RANK() OVER '
    '(ORDER BY total_bid_value DESC) computed on that grouped result -- avoids a second self-join '
    'just to learn each bidder''s placement. Ties share a rank; the next rank skips accordingly.';

-- ---------------------------------------------------------------------------
-- v_seller_revenue — SUM(final_amount) OVER (PARTITION BY seller_id
--                     ORDER BY created_at ROWS UNBOUNDED PRECEDING)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_seller_revenue AS
SELECT
    t.transaction_id,
    t.seller_id,
    u.full_name AS seller_name,
    t.final_amount,
    t.created_at,
    SUM(t.final_amount) OVER (
        PARTITION BY t.seller_id
        ORDER BY t.created_at
        ROWS UNBOUNDED PRECEDING
    ) AS running_revenue
FROM transactions t
JOIN users u ON u.user_id = t.seller_id
WHERE t.status <> 'CANCELLED';

COMMENT ON VIEW v_seller_revenue IS
    'One row per transaction (unlike GROUP BY SUM(final_amount), which would collapse straight '
    'to one row per seller), each carrying the seller''s running total up to and including that '
    'sale -- ROWS UNBOUNDED PRECEDING makes the window every prior row in that seller''s '
    'chronological order.';

-- ---------------------------------------------------------------------------
-- v_bid_momentum — LAG(amount) OVER (PARTITION BY auction_id ORDER BY placed_at)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_bid_momentum AS
SELECT
    b.bid_id,
    b.auction_id,
    b.bidder_id,
    b.amount,
    b.placed_at,
    LAG(b.amount) OVER (
        PARTITION BY b.auction_id
        ORDER BY b.placed_at
    ) AS previous_amount,
    b.amount - LAG(b.amount) OVER (
        PARTITION BY b.auction_id
        ORDER BY b.placed_at
    ) AS amount_jump
FROM bids b;

COMMENT ON VIEW v_bid_momentum IS
    'LAG(amount) looks back one row within the same auction (PARTITION BY auction_id, ORDER BY '
    'placed_at) without collapsing anything, so each bid keeps its own row alongside the jump '
    'from the previous bid. The first bid in every auction has no previous row, so LAG -- and '
    'amount_jump -- are both NULL there by definition.';

-- ---------------------------------------------------------------------------
-- v_category_leaderboard — DENSE_RANK() OVER (PARTITION BY category_id
--                           ORDER BY final_amount DESC)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_category_leaderboard AS
SELECT
    t.transaction_id,
    i.category_id,
    c.name      AS category_name,
    i.title     AS item_title,
    t.final_amount,
    DENSE_RANK() OVER (
        PARTITION BY i.category_id
        ORDER BY t.final_amount DESC
    ) AS category_rank
FROM transactions t
JOIN items i      ON i.item_id = t.item_id
JOIN categories c ON c.category_id = i.category_id
WHERE t.status <> 'CANCELLED';

COMMENT ON VIEW v_category_leaderboard IS
    'DENSE_RANK() OVER (PARTITION BY category_id ORDER BY final_amount DESC): every sale keeps '
    'its own row, ranked within its own category, with no gaps in the rank sequence after a tie '
    '(unlike RANK(), which would skip).';
