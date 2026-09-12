# BidHub — Contract

Every name shared between the database, the API and the client. The first version was
agreed in Phase 0 (plan §5) but never committed; this file was rebuilt from the code during
INT-01 (`db/01_schema.sql`, `db/02–06`, `server/src/routes/`) and is now the reference.
Anything renamed from here on needs the agreement of all three people.

Run order: `db/01_schema.sql → 02 → 03 → 04 → 05 → 06 → 07_seed.sql`
(`bash scripts/rebuild-db.sh`). Database: PostgreSQL 16, `postgresql://bidhub:bidhub@localhost:5433/bidhub`.

---

## 1. Enums

| Type | Values |
|---|---|
| `user_role` | `BUYER`, `SELLER`, `ADMIN` |
| `item_condition` | `NEW`, `LIKE_NEW`, `USED`, `REFURBISHED` |
| `auction_status` | `SCHEDULED`, `ACTIVE`, `CLOSED`, `CANCELLED` |
| `notification_type` | `OUTBID`, `WON`, `SOLD`, `AUCTION_CLOSED` |
| `transaction_status` | `PENDING`, `PAID`, `SHIPPED`, `COMPLETED`, `CANCELLED` |

Money is `NUMERIC(12,2)`. Timestamps are `TIMESTAMPTZ`. Surrogate keys are `SERIAL`
(`audit_log.audit_id` is `BIGSERIAL`).

## 2. Tables

### users
| Column | Type | Null | Default | Key / rule |
|---|---|---|---|---|
| user_id | SERIAL | no | | PK |
| full_name | VARCHAR(120) | no | | |
| email | VARCHAR(255) | no | | `uq_users_email`, `chk_users_email_format` |
| password_hash | TEXT | no | | bcrypt, never returned by the API |
| role | user_role | no | `'BUYER'` | |
| created_at | TIMESTAMPTZ | no | `now()` | |

### categories
| Column | Type | Null | Default | Key / rule |
|---|---|---|---|---|
| category_id | SERIAL | no | | PK |
| name | VARCHAR(100) | no | | |
| slug | VARCHAR(120) | no | | `uq_categories_slug` |
| parent_id | INT | yes | | FK → categories (RESTRICT); `chk_categories_no_self_parent` |
| created_at | TIMESTAMPTZ | no | `now()` | |

### items
| Column | Type | Null | Default | Key / rule |
|---|---|---|---|---|
| item_id | SERIAL | no | | PK |
| seller_id | INT | no | | FK → users (RESTRICT) |
| category_id | INT | no | | FK → categories (RESTRICT) |
| title | VARCHAR(200) | no | | |
| description | TEXT | yes | | |
| condition | item_condition | no | `'USED'` | |
| attributes | JSONB | no | `'{}'` | domain-specific spec, e.g. `{"ram":"16GB"}` |
| image_url | TEXT | yes | | |
| created_at | TIMESTAMPTZ | no | `now()` | |

### auctions
| Column | Type | Null | Default | Key / rule |
|---|---|---|---|---|
| auction_id | SERIAL | no | | PK |
| item_id | INT | no | | FK → items (RESTRICT); `uq_auctions_item` |
| starting_price | NUMERIC(12,2) | no | | `> 0` |
| reserve_price | NUMERIC(12,2) | yes | | `NULL` or `>= starting_price` |
| bid_increment | NUMERIC(12,2) | no | `1.00` | `> 0` |
| start_time | TIMESTAMPTZ | no | `now()` | |
| end_time | TIMESTAMPTZ | no | | `> start_time` |
| status | auction_status | no | `'SCHEDULED'` | |
| winning_bid_id | INT | yes | | FK → bids (SET NULL), set by `award_winner` |
| created_at | TIMESTAMPTZ | no | `now()` | |

### bids
| Column | Type | Null | Default | Key / rule |
|---|---|---|---|---|
| bid_id | SERIAL | no | | PK |
| auction_id | INT | no | | FK → auctions (CASCADE) |
| bidder_id | INT | no | | FK → users (RESTRICT) |
| amount | NUMERIC(12,2) | no | | `> 0` |
| placed_at | TIMESTAMPTZ | no | `now()` | |

### transactions
| Column | Type | Null | Default | Key / rule |
|---|---|---|---|---|
| transaction_id | SERIAL | no | | PK |
| auction_id | INT | no | | FK → auctions (RESTRICT); `uq_transactions_auction` |
| buyer_id | INT | no | | FK → users (RESTRICT) |
| seller_id | INT | no | | FK → users (RESTRICT) |
| item_id | INT | no | | FK → items (RESTRICT) |
| final_amount | NUMERIC(12,2) | no | | `> 0` |
| status | transaction_status | no | `'PENDING'` | |
| created_at | TIMESTAMPTZ | no | `now()` | |

Written only by `trg_close_auction`.

### notifications
| Column | Type | Null | Default | Key / rule |
|---|---|---|---|---|
| notification_id | SERIAL | no | | PK |
| user_id | INT | no | | FK → users (CASCADE) |
| type | notification_type | no | | |
| title | VARCHAR(150) | no | | |
| message | TEXT | no | | |
| auction_id | INT | yes | | FK → auctions (CASCADE) |
| is_read | BOOLEAN | no | `false` | |
| created_at | TIMESTAMPTZ | no | `now()` | |

Written only by `trg_outbid` and `trg_close_auction`; the API reads and marks as read.

### audit_log
| Column | Type | Null | Default | Key / rule |
|---|---|---|---|---|
| audit_id | BIGSERIAL | no | | PK |
| actor_id | INT | yes | | FK → users (SET NULL) |
| action | VARCHAR(50) | no | | e.g. `BID_PLACED` |
| entity_type | VARCHAR(50) | no | | e.g. `auction` |
| entity_id | INT | no | | |
| payload | JSONB | no | `'{}'` | |
| occurred_at | TIMESTAMPTZ | no | `now()` | |

Append-only: `trg_audit_immutable` rejects every UPDATE and DELETE. That includes the
UPDATE issued by `ON DELETE SET NULL`, so a user with audited activity cannot be deleted.

### watchlist
| Column | Type | Null | Default | Key / rule |
|---|---|---|---|---|
| user_id | INT | no | | PK part; FK → users (CASCADE) |
| auction_id | INT | no | | PK part; FK → auctions (CASCADE) |
| created_at | TIMESTAMPTZ | no | `now()` | |

## 3. Database routines, triggers, views and indexes

| Name | Kind | File | Technique |
|---|---|---|---|
| `place_bid(p_user_id INT, p_auction_id INT, p_amount NUMERIC)` | PROCEDURE | 03 | 03, 08 |
| `award_winner(p_auction_id INT)` | PROCEDURE | 03 | 02 |
| `close_expired_auctions()` | PROCEDURE (explicit cursor) | 03 | 06 |
| `refresh_leaderboard()` | PROCEDURE | 06 | 10 |
| `get_leaderboard(p_auction_id INT)` | FUNCTION → `position, bidder_id, bidder_name, item_title, amount, placed_at, is_leading` | 04 | 04 |
| `get_category_tree(p_root_id INT DEFAULT NULL)` | FUNCTION → `category_id, name, slug, parent_id, depth, path TEXT[]` | 04 | 07 |
| `get_category_breadcrumb(p_category_id INT)` | FUNCTION → `category_id, name, slug, parent_id, depth` (root first) | 04 | 07 |
| `get_category_item_counts()` | FUNCTION → `category_id, name, direct_items, subtree_items` | 04 | 07 |
| `v_top_bidders` | VIEW, `RANK()` | 04 | 05 |
| `v_seller_revenue` | VIEW, running `SUM() OVER` | 04 | 05 |
| `v_bid_momentum` | VIEW, `LAG()` | 04 | 05 |
| `v_category_leaderboard` | VIEW, `DENSE_RANK()` | 04 | 05 |
| `v_auction_summary` | VIEW, the report `mv_leaderboard` stores | 06 | 10 |
| `v_active_auctions` | VIEW, live auctions | 06 | 10 |
| `mv_leaderboard` | MATERIALIZED VIEW, unique index `uq_mv_leaderboard_auction` | 06 | 10 |
| `trg_outbid` | AFTER INSERT ON bids | 02 | 01 |
| `trg_audit_bid` | AFTER INSERT ON bids | 02 | audit |
| `trg_audit_immutable` | BEFORE UPDATE OR DELETE ON audit_log | 02 | audit |
| `trg_close_auction` | AFTER UPDATE ON auctions, `WHEN (OLD.status = 'ACTIVE' AND NEW.status = 'CLOSED')` | 02 | 02 |
| `idx_bids_auction_amount` | INDEX `bids (auction_id, amount DESC)` | 05 | 09 |
| `idx_auctions_active_end` | partial INDEX `auctions (end_time) WHERE status = 'ACTIVE'` | 05 | 09 |
| `idx_items_category`, `idx_items_seller`, `idx_bids_bidder_placed`, `idx_categories_parent` | FK / lookup indexes | 05 | 09 |
| `idx_notifications_user_unread` | partial INDEX `notifications (user_id) WHERE is_read = false` | 05 | 09 |
| `idx_items_attributes` | GIN `jsonb_path_ops` | 05 | 09 |
| `idx_items_title_trgm` | GIN `gin_trgm_ops` (extension `pg_trgm`) | 05 | 09 |

## 4. Errors

Every error response has the same envelope:

```json
{ "error": { "code": "AU001", "message": "bid 105.00 is below the minimum required bid of 110.00" } }
```

| Code | HTTP | Source |
|---|---|---|
| `AU001` | 400 | `place_bid`: amount below current high bid + increment (or below starting price) |
| `AU002` | 409 | `place_bid`: auction not ACTIVE or past `end_time` |
| `AU003` | 403 | `place_bid`: seller bidding on their own auction |
| `AU004` | 404 | `place_bid`: auction does not exist |
| `UNIQUE_VIOLATION` | 409 | SQLSTATE 23505 |
| `FOREIGN_KEY_VIOLATION` | 400 | SQLSTATE 23503 |
| `CHECK_VIOLATION` | 400 | SQLSTATE 23514 |
| `VALIDATION_ERROR` | 400 | missing field, malformed JSON, SQLSTATE 23502 / 22P02 / 22003 / 22007 / 22008 |
| `AUTH_REQUIRED`, `AUTH_INVALID` | 401 | missing / bad / expired JWT |
| `INVALID_CREDENTIALS` | 401 | wrong email or password |
| `AUTH_FORBIDDEN` | 403 | wrong role, or not the item's owner |
| `NOT_FOUND` | 404 | unknown route or row |
| `PAYLOAD_TOO_LARGE` | 413 | body over 1 MB |
| `RATE_LIMITED` | 429 | more than 20 `/api/auth` requests per 15 minutes |
| `INTERNAL_ERROR` | 500 | anything else; details only in the server log |

The `AU00x` messages come straight from `RAISE EXCEPTION` in `place_bid`. Integrity
errors never pass PostgreSQL's text through: the API sends a sentence per constraint, or
the generic fallback.

## 5. REST API

Base URL `http://localhost:4000/api`. Auth is `Authorization: Bearer <JWT>` (claims `sub`,
`email`, `role`; lifetime `JWT_EXPIRES_IN`, default 24 h).

| Method | Path | Auth | Body / query | Response |
|---|---|---|---|---|
| GET | `/health` | — | | `{ ok, db }` |
| POST | `/auth/register` | — | `{ full_name, email, password, role? }` (`BUYER`\|`SELLER`) | 201 `{ user, token }` |
| POST | `/auth/login` | — | `{ email, password }` | `{ user, token }` |
| GET | `/auth/me` | any | | `{ user }` |
| GET | `/categories/tree` | — | `?root_id=` | `{ categories: [ { …, depth, path, children: [...] } ] }` |
| GET | `/categories/:id/breadcrumb` | — | | `{ breadcrumb: [ root … leaf ] }` |
| GET | `/items` | — | `?category=&seller=&q=&page=&limit=` (limit ≤ 100, default 20) | `{ items, page, limit }` |
| POST | `/items` | SELLER | `{ category_id, title, description?, condition?, attributes?, image_url? }` | 201 `{ item }` |
| GET | `/items/:id` | — | | `{ item }` (+ `category_name`, `seller_name`) |
| GET | `/auctions` | — | `?status=` | `{ auctions }` (+ `item_title`, `image_url`, `category_id`, `current_high_bid`, `bid_count`), by `end_time` |
| POST | `/auctions` | SELLER, item owner | `{ item_id, starting_price, bid_increment, end_time, reserve_price? }` | 201 `{ auction }`, created `ACTIVE` |
| GET | `/auctions/:id` | — | | `{ auction }` |
| POST | `/auctions/:id/bids` | any | `{ amount }` | 201 `{ ok: true }`, or `AU001–AU004` |
| GET | `/auctions/:id/leaderboard` | — | | `{ leaderboard }` (rows of `get_leaderboard`) |
| GET | `/me/bids` | any | | `{ bids }` (+ `auction_status`, `item_title`, `won`) |
| GET | `/notifications` | any | | `{ notifications }`, unread first |
| GET | `/notifications/unread-count` | any | | `{ unread }` |
| PATCH | `/notifications/:id/read` | owner | | `{ notification }` |
| GET | `/analytics/top-bidders` | — | | `{ top_bidders }` (`v_top_bidders`, top 50) |
| GET | `/analytics/seller-revenue` | — | | `{ seller_revenue }` (`v_seller_revenue`) |

## 6. File ownership

| Path | Owner |
|---|---|
| `CONTRACT.md`, `docker-compose.yml`, `db/01_schema.sql`, `db/02_triggers.sql`, `db/tests/test_schema.sql`, `db/tests/test_triggers.sql`, `db/tests/test_concurrency.sql`, `db/tests/concurrency.sh`, `docs/er-diagram.md`, `docs/data-dictionary.md`, `docs/normalization.md`, `docs/acid-notes.md` | P1 — Database Core |
| `db/03_procedures.sql`, `db/04_queries.sql`, `db/05_indexes.sql`, `db/06_views.sql`, `db/tests/test_procedures.sql`, `db/tests/test_queries.sql`, `db/tests/test_views.sql`, `db/tests/benchmark.sql`, `docs/performance.md`, `docs/technique-report.md` | P2 — Procedural SQL & Performance |
| `db/07_seed.sql`, `server/`, `client/`, `docs/demo-script.md` | P3 — Application |
| `scripts/`, `README.md` | shared (INT-01) |

Nobody edits another person's files on a parallel branch. Cross-cutting fixes go through
an integration branch that all three review.

## 7. Drift from the Phase 0 plan

Recorded during INT-01. The code is what counts; the plan text is out of date on these points.

- **Port:** the database is published on host port **5433**, not 5432, so it doesn't clash with a local PostgreSQL.
- **Routines added:** `get_category_breadcrumb`, `get_category_item_counts`, `refresh_leaderboard`, and the views `v_top_bidders`, `v_seller_revenue`, `v_bid_momentum`, `v_category_leaderboard`, `v_auction_summary`, `v_active_auctions`.
- **`get_category_tree`** takes `p_root_id INT DEFAULT NULL`; `NULL` returns the whole forest.
- **Routes added:** `GET /api/health`, and `GET /api/notifications/unread-count` (INT-01, so the header bell uses `idx_notifications_user_unread` instead of downloading every notification).
- **`POST /api/auctions`** creates the auction `ACTIVE` immediately; nothing in the API creates a `SCHEDULED` auction (only the seed does).
- **`POST /api/auth/register`** accepts an optional `role`, limited to `BUYER` or `SELLER`.
- **Not exposed by the API:** `watchlist` (table only), `v_bid_momentum` and `v_category_leaderboard` (database only).
