# Data dictionary

Every table and column in `db/01_schema.sql`, as the code defines them. Where a business
rule is enforced by something other than a column constraint (a procedure, a trigger or
the API), the rule says where. Index definitions come from `db/05_indexes.sql`.

**Key column:** `PK` primary key · `FK → t` foreign key to table `t` · `UQ` unique.
Money is `NUMERIC(12,2)` throughout; every timestamp is `TIMESTAMPTZ`.

## Enumerated types

| Type | Values (in declared order) | Used by |
|---|---|---|
| `user_role` | `BUYER`, `SELLER`, `ADMIN` | `users.role` |
| `item_condition` | `NEW`, `LIKE_NEW`, `USED`, `REFURBISHED` | `items.condition` |
| `auction_status` | `SCHEDULED`, `ACTIVE`, `CLOSED`, `CANCELLED` | `auctions.status` |
| `notification_type` | `OUTBID`, `WON`, `SOLD`, `AUCTION_CLOSED` | `notifications.type` |
| `transaction_status` | `PENDING`, `PAID`, `SHIPPED`, `COMPLETED`, `CANCELLED` | `transactions.status` |

Enums are created inside `DO $$ ... EXCEPTION WHEN duplicate_object` blocks. A value
outside the list is rejected by PostgreSQL itself; the API turns that into
`400 VALIDATION_ERROR`.

---

## users

Everyone who uses the platform. A single table with a role column, rather than separate
buyer and seller tables, because one person often does both. Sellers may bid on other
sellers' auctions; the only restriction, bidding on your own listing, is enforced by
`place_bid` (AU003).

| Column | Type | Null | Default | Key | Constraint | Business rule |
|---|---|---|---|---|---|---|
| user_id | SERIAL | no | sequence | PK | | Surrogate id, referenced by six other tables. |
| full_name | VARCHAR(120) | no | | | | Display name on leaderboards, listings and notifications. |
| email | VARCHAR(255) | no | | UQ | `uq_users_email`, `chk_users_email_format` | Login identifier, one account per address. The CHECK (`~*` regex `^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$`) rejects malformed addresses at the database boundary. |
| password_hash | TEXT | no | | | | bcrypt hash (12 rounds from the API, 12 in the seed). Only the login query ever selects it. |
| role | user_role | no | `'BUYER'` | | | `SELLER` is required to create items and auctions (API `requireRole`). `ADMIN` exists only in the seed. Self-registration may pick `BUYER` or `SELLER`. |
| created_at | TIMESTAMPTZ | no | `now()` | | | Account creation time. |

**Indexes:** primary key; unique index behind `uq_users_email`.

---

## categories

The catalog hierarchy, stored as an adjacency list: each row points at its parent. Any
domain, any depth: Electronics → Computers → Laptops → Gaming Laptops sits next to
Art & Collectibles → Paintings → Oil Paintings. The original design fixed three levels
(brand → line → variant); this table replaces them with one self-referencing relation,
traversed by `get_category_tree`, `get_category_breadcrumb` and
`get_category_item_counts` (`WITH RECURSIVE`, `db/04_queries.sql`).

| Column | Type | Null | Default | Key | Constraint | Business rule |
|---|---|---|---|---|---|---|
| category_id | SERIAL | no | sequence | PK | `chk_categories_no_self_parent` | Surrogate id. |
| name | VARCHAR(100) | no | | | | Display name. Not unique: two branches may both have "Accessories". |
| slug | VARCHAR(120) | no | | UQ | `uq_categories_slug` | URL-safe identifier, unique across the whole tree. |
| parent_id | INT | yes | | FK → categories | `fk_categories_parent` (ON DELETE RESTRICT), `chk_categories_no_self_parent` | NULL marks a root. RESTRICT: a category with children can't be deleted. The CHECK stops a category from being its own parent. Longer cycles are not blocked by a constraint; the recursive functions stop at depth 20 as a guard. |
| created_at | TIMESTAMPTZ | no | `now()` | | | |

**Indexes:** primary key; `uq_categories_slug`; `idx_categories_parent (parent_id)`, the
join in every recursive step.

---

## items

A thing being sold, in any domain. Descriptive facts only: price, timing and status
belong to the auction. `attributes` is JSONB, so a laptop (`{"ram":"32GB","cpu":"i9"}`),
a painting (`{"medium":"oil","year":"1962"}`) and a car (`{"mileage":"82000"}`) share one
table without a sparse column per possible property.

| Column | Type | Null | Default | Key | Constraint | Business rule |
|---|---|---|---|---|---|---|
| item_id | SERIAL | no | sequence | PK | | Surrogate id. |
| seller_id | INT | no | | FK → users | `fk_items_seller` (RESTRICT) | The listing user. The API sets it from the JWT, never from the request body. |
| category_id | INT | no | | FK → categories | `fk_items_category` (RESTRICT) | Normally a leaf, though any node is allowed. A category with items can't be deleted. |
| title | VARCHAR(200) | no | | | | Searchable by substring (`ILIKE`), backed by the trigram index. |
| description | TEXT | yes | | | | Free text. |
| condition | item_condition | no | `'USED'` | | | |
| attributes | JSONB | no | `'{}'` | | | Domain-specific specification, rendered as a spec table in the UI and searchable with `@>`. |
| image_url | TEXT | yes | | | | |
| created_at | TIMESTAMPTZ | no | `now()` | | | Catalog sort order (newest first). |

**Indexes:** primary key; `idx_items_seller (seller_id)`; `idx_items_category
(category_id)`; `idx_items_attributes` GIN `jsonb_path_ops`; `idx_items_title_trgm` GIN
`gin_trgm_ops`.

---

## auctions

One timed sale of one item: the terms (prices, increment, window) and the lifecycle
state. This is the row `place_bid` locks (`FOR UPDATE`) so that concurrent bids on the
same auction run one after another.

| Column | Type | Null | Default | Key | Constraint | Business rule |
|---|---|---|---|---|---|---|
| auction_id | SERIAL | no | sequence | PK | | Surrogate id. |
| item_id | INT | no | | FK → items, UQ | `fk_auctions_item` (RESTRICT), `uq_auctions_item` | An item is auctioned at most once; to relist, create a new item. |
| starting_price | NUMERIC(12,2) | no | | | `chk_auctions_starting_price_positive` (`> 0`) | The first bid must be at least this. |
| reserve_price | NUMERIC(12,2) | yes | | | `chk_auctions_reserve_at_least_starting` | Hidden minimum. NULL means no reserve. If the winning bid is below it, `trg_close_auction` does not sell and notifies the seller instead. |
| bid_increment | NUMERIC(12,2) | no | `1.00` | | `chk_auctions_bid_increment_positive` (`> 0`) | Each new bid must be at least current high + increment. A zero increment would let a tying bid through. |
| start_time | TIMESTAMPTZ | no | `now()` | | `chk_auctions_end_after_start` | |
| end_time | TIMESTAMPTZ | no | | | `chk_auctions_end_after_start` (`end_time > start_time`) | After this moment `place_bid` rejects bids (AU002) and `close_expired_auctions` closes the auction. |
| status | auction_status | no | `'SCHEDULED'` | | | `ACTIVE` → `CLOSED` is performed by the cursor procedure and fires settlement. No routine promotes `SCHEDULED` to `ACTIVE`: the seed and `POST /api/auctions` set `ACTIVE` directly. |
| winning_bid_id | INT | yes | | FK → bids | `fk_auctions_winning_bid` (ON DELETE SET NULL) | Set by `award_winner()` after close. Stays NULL with no bids or an unmet reserve. Added by `ALTER TABLE` because auctions and bids reference each other. |
| created_at | TIMESTAMPTZ | no | `now()` | | | |

**Indexes:** primary key; `uq_auctions_item`; `idx_auctions_active_end (end_time) WHERE
status = 'ACTIVE'`, a partial index for the close cursor and the homepage.

---

## bids

Every bid ever accepted. Rejected bids never reach the table: `place_bid` raises before
the INSERT. Rows are only ever inserted, and each insert fires `trg_outbid` and
`trg_audit_bid`.

| Column | Type | Null | Default | Key | Constraint | Business rule |
|---|---|---|---|---|---|---|
| bid_id | SERIAL | no | sequence | PK | | Surrogate id. |
| auction_id | INT | no | | FK → auctions | `fk_bids_auction` (ON DELETE CASCADE) | Bids belong wholly to their auction. |
| bidder_id | INT | no | | FK → users | `fk_bids_bidder` (RESTRICT) | Must not be the item's seller (AU003, `place_bid`). |
| amount | NUMERIC(12,2) | no | | | `chk_bids_amount_positive` (`> 0`) | Floor check only. The real minimum (high bid + increment, or the starting price for the first bid) is enforced by `place_bid` (AU001). |
| placed_at | TIMESTAMPTZ | no | `now()` | | | Tie-break: at equal amounts the earlier bid leads, everywhere (`place_bid`, triggers, `award_winner`, `get_leaderboard`, `mv_leaderboard`). |

**Indexes:** primary key; `idx_bids_auction_amount (auction_id, amount DESC)`, the
composite index (technique 09); `idx_bids_bidder_placed (bidder_id, placed_at DESC)`.

---

## transactions

The settled sale: who bought what from whom, at what price. A historical record that is
written once, when the auction closes, by `trg_close_auction` and nothing else. The API
never inserts here.

| Column | Type | Null | Default | Key | Constraint | Business rule |
|---|---|---|---|---|---|---|
| transaction_id | SERIAL | no | sequence | PK | | Surrogate id. |
| auction_id | INT | no | | FK → auctions, UQ | `fk_transactions_auction` (RESTRICT), `uq_transactions_auction` | One settlement per auction. The trigger's `ON CONFLICT ... DO NOTHING` relies on it to stay safe under a double close. |
| buyer_id | INT | no | | FK → users | `fk_transactions_buyer` (RESTRICT) | The winning bidder, copied at settlement. |
| seller_id | INT | no | | FK → users | `fk_transactions_seller` (RESTRICT) | The item's seller, copied at settlement. |
| item_id | INT | no | | FK → items | `fk_transactions_item` (RESTRICT) | Copied at settlement. |
| final_amount | NUMERIC(12,2) | no | | | `chk_transactions_amount_positive` (`> 0`) | The winning bid's amount. Feeds `v_seller_revenue` and `v_category_leaderboard`. |
| status | transaction_status | no | `'PENDING'` | | | Settlement always writes `PENDING`. There is no fulfilment workflow in the API yet; the seed uses `COMPLETED` for history. Analytics exclude `CANCELLED`. |
| created_at | TIMESTAMPTZ | no | `now()` | | | Order of the running revenue total. |

**Indexes:** primary key; `uq_transactions_auction`.

---

## notifications

Messages to a user, written only by triggers: `OUTBID` from `trg_outbid`, and `WON`,
`SOLD` and `AUCTION_CLOSED` from `trg_close_auction`. The API only reads them and marks
them as read, so the bell is direct evidence that the triggers fired.

| Column | Type | Null | Default | Key | Constraint | Business rule |
|---|---|---|---|---|---|---|
| notification_id | SERIAL | no | sequence | PK | | Surrogate id. |
| user_id | INT | no | | FK → users | `fk_notifications_user` (ON DELETE CASCADE) | The recipient. |
| type | notification_type | no | | | | Drives the colour in the UI. |
| title | VARCHAR(150) | no | | | | Short headline, e.g. "You have been outbid". |
| message | TEXT | no | | | | Rendered at write time with the item title and amount. A notification is a message that was sent, so it does not change if the item is edited later. |
| auction_id | INT | yes | | FK → auctions | `fk_notifications_auction` (ON DELETE CASCADE) | The auction it concerns. |
| is_read | BOOLEAN | no | `false` | | | Set by `PATCH /api/notifications/:id/read`, for the owner only. |
| created_at | TIMESTAMPTZ | no | `now()` | | | |

**Indexes:** primary key; `idx_notifications_user_unread (user_id) WHERE is_read =
false`, a partial index that serves `GET /api/notifications/unread-count`.

---

## audit_log

A tamper-evident trail of activity. Each row records who did what to which entity, and
the relevant values at that moment (`payload`). `trg_audit_immutable` rejects every
UPDATE and DELETE, even from a superuser in psql, so the table is append-only in fact,
not just by convention.

| Column | Type | Null | Default | Key | Constraint | Business rule |
|---|---|---|---|---|---|---|
| audit_id | BIGSERIAL | no | sequence | PK | | 64-bit, because this table grows fastest and is never pruned. |
| actor_id | INT | yes | | FK → users | `fk_audit_log_actor` (ON DELETE SET NULL) | Who acted. Nullable for system actions. The SET NULL is itself blocked by the immutability trigger (see [er-diagram.md](er-diagram.md#delete-behaviour)). |
| action | VARCHAR(50) | no | | | | Verb. Today only `BID_PLACED` is written (`trg_audit_bid`). |
| entity_type | VARCHAR(50) | no | | | | Which kind of entity, e.g. `auction`. |
| entity_id | INT | no | | | | Id within `entity_type`. Deliberately **no foreign key**: the log must be able to point at any table and outlive the row. |
| payload | JSONB | no | `'{}'` | | | Snapshot of the event, e.g. `{"bid_id":…, "amount":…, "placed_at":…}`. |
| occurred_at | TIMESTAMPTZ | no | `now()` | | | |

**Indexes:** primary key.

---

## watchlist

Users saving auctions to follow: a many-to-many junction between `users` and `auctions`.
The table and its keys exist, but no API route reads or writes it yet
([contract.md](contract.md) §7).

| Column | Type | Null | Default | Key | Constraint | Business rule |
|---|---|---|---|---|---|---|
| user_id | INT | no | | PK, FK → users | `pk_watchlist`, `fk_watchlist_user` (ON DELETE CASCADE) | The watching user. |
| auction_id | INT | no | | PK, FK → auctions | `pk_watchlist`, `fk_watchlist_auction` (ON DELETE CASCADE) | The watched auction. The composite key means each user watches each auction at most once. |
| created_at | TIMESTAMPTZ | no | `now()` | | | |

**Indexes:** primary key `(user_id, auction_id)`.

---

## Derived objects (not base tables)

These hold no data of their own, except the materialized view, which is a refreshable
cache. They are listed so the dictionary covers every name the API and the demo use.

| Object | Kind | Defined in | Contents |
|---|---|---|---|
| `v_top_bidders` | view | `db/04_queries.sql` | Per bidder: bid count, total bid value, `RANK()` by total. |
| `v_seller_revenue` | view | `db/04_queries.sql` | Per transaction: running `SUM(final_amount) OVER (PARTITION BY seller_id ORDER BY created_at)`. |
| `v_bid_momentum` | view | `db/04_queries.sql` | Per bid: previous amount in the auction and the jump, via `LAG()`. |
| `v_category_leaderboard` | view | `db/04_queries.sql` | Per sale: `DENSE_RANK()` of the price within its category. |
| `v_auction_summary` | view | `db/06_views.sql` | One row per auction: item, category, seller, high bid and leader, bid counts, time left. |
| `v_active_auctions` | view | `db/06_views.sql` | Live auctions with current high bid and bid count. |
| `mv_leaderboard` | materialized view | `db/06_views.sql` | Stored snapshot of `v_auction_summary`. `computed_at` is the refresh time. Unique index `uq_mv_leaderboard_auction (auction_id)`. |
