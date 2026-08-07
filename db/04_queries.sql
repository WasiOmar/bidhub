CREATE OR REPLACE FUNCTION get_leaderboard(p_auction_id INT)
RETURNS TABLE (
    "position"     INT,
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
    WITH max_bids_per_user AS (
        SELECT
            b.bidder_id,
            u.full_name AS bidder_name,
            i.title     AS item_title,
            MAX(b.amount)    AS amount,
            MAX(b.placed_at) AS placed_at
        FROM bids b
        JOIN users u    ON u.user_id = b.bidder_id
        JOIN auctions a ON a.auction_id = b.auction_id
        JOIN items i    ON i.item_id = a.item_id
        WHERE b.auction_id = p_auction_id
        GROUP BY b.bidder_id, u.full_name, i.title
    ),
    ranked_bids AS (
        SELECT
            bidder_id,
            bidder_name,
            item_title,
            amount,
            placed_at,
            ROW_NUMBER() OVER (
                ORDER BY amount DESC, placed_at ASC
            ) AS position
        FROM max_bids_per_user
    )
    SELECT
        "position"::INT,
        bidder_id,
        bidder_name,
        item_title,
        amount,
        placed_at,
        ("position" = 1) AS is_leading
    FROM ranked_bids
    ORDER BY "position";
$$;
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
        SELECT
            c.category_id, c.name, c.slug, c.parent_id,
            0 AS depth,
            ARRAY[c.name]::TEXT[] AS path
        FROM categories c
        WHERE (p_root_id IS NULL AND c.parent_id IS NULL)
           OR (p_root_id IS NOT NULL AND c.category_id = p_root_id)
        UNION ALL
        SELECT
            child.category_id, child.name, child.slug, child.parent_id,
            parent.depth + 1,
            parent.path || child.name
        FROM categories child
        JOIN cat_tree parent ON child.parent_id = parent.category_id
        WHERE parent.depth < 20
          AND NOT (parent.path @> ARRAY[child.name]::TEXT[])
    )
    SELECT category_id, name, slug, parent_id, depth, path
    FROM cat_tree
    ORDER BY path;
$$;
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
        SELECT c.category_id, c.name, c.slug, c.parent_id, 0 AS depth
        FROM categories c
        WHERE c.category_id = p_category_id
        UNION ALL
        SELECT p.category_id, p.name, p.slug, p.parent_id, a.depth + 1
        FROM categories p
        JOIN ancestors a ON p.category_id = a.parent_id
        WHERE a.depth < 20
    )
    SELECT category_id, name, slug, parent_id, depth
    FROM ancestors
    ORDER BY depth DESC;
$$;
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
        SELECT c.category_id AS ancestor_id, c.category_id AS descendant_id, 0 AS depth
        FROM categories c
        UNION ALL
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