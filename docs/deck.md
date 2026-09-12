---
marp: true
theme: default
paginate: true
title: BidHub — a general-purpose auction platform
---

<!-- Slide structure follows the original 12-slide deck. Marp renders this file
     directly; reveal.js (markdown plugin) splits on the same --- separators. -->

<!-- _paginate: false -->

TEAM OF 3 · DBMS LAB PROJECT · 2026 · ARMK SIR

# BidHub

## A general-purpose online auction platform

PostgreSQL 16 · Node.js · React

---

# Project overview

> Online auctions sell everything from laptops to classic cars, and every one of them
> depends on the same guarantee: the highest valid bid wins, exactly once, no matter how
> many people click at the same second.

BidHub builds that guarantee **into PostgreSQL**. The database validates every bid,
notifies the outbid, settles the sale and keeps the audit trail. The API calls it; it
does not re-implement it.

| Featured lot (from our seed data) | Category path | Opens at |
|---|---|---|
| Vortex X15 Gaming Laptop | Electronics → Computers → Laptops → Gaming Laptops | $1,200 |
| 1966 Shelby GT350 | Vehicles → Cars → Classic Cars | $45,000 |
| Coastal Cliffs in Morning Light | Art & Collectibles → Paintings → Oil Paintings | $1,200 |
| PRS Custom 24 | Musical Instruments → String → Guitars → Electric Guitars | $2,600 |
| Harry Potter and the Philosopher's Stone | Books → Rare Books → First Editions | $4,000 |

---

# Platform features

| | | |
|---|---|---|
| **01 Registration & auth**<br>Buyer and seller roles, JWT sessions, bcrypt hashes stored in PostgreSQL. | **02 Listings & catalog**<br>Any item, any domain: a category tree of any depth, walked by a recursive CTE, with JSONB specs per item. | **03 Live bidding engine**<br>Atomic bid placement through a stored procedure; concurrent bids serialised by a row lock. |
| **04 Timer & auto-close**<br>A cursor-driven procedure closes expired auctions; a trigger settles each sale. | **05 History & analytics**<br>Append-only audit log; window-function analytics over bids and sales. | **06 Smart notifications**<br>Outbid, won, sold and closed alerts written by `AFTER` triggers, not by the API. |

---

# Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  FRONTEND   React SPA (Vite)                                 │
│  Browse tree · Auction page · Bid panel · Bell · Analytics   │
└───────────────────────────┬──────────────────────────────────┘
                            │  HTTP / REST, JSON error envelope
┌───────────────────────────▼──────────────────────────────────┐
│  BACKEND    Node.js + Express + node-postgres                │
│  JWT auth · CALL place_bid · SQLSTATE → HTTP mapping         │
└───────────────────────────┬──────────────────────────────────┘
                            │  one pooled connection per request
┌───────────────────────────▼──────────────────────────────────┐
│  DATABASE — PRIMARY FOCUS   PostgreSQL 16                    │
│  Triggers · Procedures · CTEs · Cursor · Indexes · Views     │
│  Transactions · Materialized view · Append-only audit        │
└──────────────────────────────────────────────────────────────┘
```

---

# DBMS features in BidHub

| # | Platform feature | Database technique | SQL construct |
|---|---|---|---|
| 01 | Outbid notification | Event-driven alert on INSERT | `TRIGGER` |
| 02 | Auction auto-close | Settlement on status change | `TRIGGER` + `PROCEDURE` |
| 03 | Place bid (validation) | Transactional business logic | `STORED PROCEDURE` |
| 04 | Auction leaderboard | Leading bid per auction | `CTE` + `ROW_NUMBER()` |
| 05 | Top bidder analytics | Ordered aggregation, running totals | `WINDOW FUNCTIONS` |
| 06 | Expire auctions (batch) | Row-by-row procedural iteration | `CURSOR` |
| 07 | **Category tree** | Hierarchy of any depth | `RECURSIVE CTE` |
| 08 | Concurrent bid safety | All-or-nothing, serialised commit | `ACID TRANSACTION` |
| 09 | Fast bid lookup | Sorted index scan | `COMPOSITE INDEX` |
| 10 | Live auction report | Pre-computed result set | `MATERIALIZED VIEW` |

`bash scripts/verify-all.sh` → **10/10 PASS** on a freshly rebuilt database.

---

# Feature 01 — Triggers

**`trg_outbid` · AFTER INSERT ON bids.** Finds the bidder just displaced and writes their
`OUTBID` notification in the same transaction as the bid. No application code is on the
notification path.

**`trg_close_auction` · AFTER UPDATE ON auctions `WHEN (OLD.status = 'ACTIVE' AND NEW.status = 'CLOSED')`.**
Fires on the status flip however it happens. It writes the `transactions` row plus `WON`
and `SOLD` (or `AUCTION_CLOSED` when there are no bids or the reserve is not met).

**`trg_audit_bid` / `trg_audit_immutable`.** Every bid appends a JSONB snapshot to
`audit_log`, and any `UPDATE` or `DELETE` on it raises, even from the database owner.

- `FOR EACH ROW` gives the trigger `NEW` and `OLD`: exactly what changed
- One bid INSERT fires two triggers, and all three writes commit or roll back together

---

# Feature 02 — Stored procedures

| `place_bid(user, auction, amount)` | `close_expired_auctions()` |
|---|---|
| Locks the auction `FOR UPDATE`, then checks: exists (AU004), open (AU002), not your own listing (AU003), at least high bid + increment (AU001). Then inserts. | A cursor over expired `ACTIVE` auctions. Each is closed `WHERE CURRENT OF`, which fires settlement. Then refreshes the report. |
| **`award_winner(auction)`** | **`get_leaderboard(auction)`** |
| Stamps `winning_bid_id` using the platform-wide tie-break: highest amount, then earliest bid. | Returns the ranked leaderboard as a result set: one row per bidder. |

- `DECLARE` scopes `v_max_amount`, `v_min_required` before any write happens
- `RAISE EXCEPTION ... USING ERRCODE = 'AU001'` travels to Node, becomes HTTP 400 and
  reaches the screen as "Your bid is too low — minimum is X"
- `COALESCE(MAX(amount), starting_price − increment)` makes the first bid's floor
  exactly the starting price

---

# Feature 03 — CTEs & window functions

**Common table expressions**

- `max_bids_per_user` → `ranked_bids`: the leaderboard in two named steps
- `WITH RECURSIVE cat_tree`: the category hierarchy to any depth
- `ranked_bids` + `bid_stats`: the per-auction report behind `mv_leaderboard`

**Window functions**

- `ROW_NUMBER() OVER (ORDER BY amount DESC, placed_at ASC)`: one leader, positions 1..n
- `RANK() OVER (ORDER BY SUM(amount) DESC)`: top bidders; ties share a rank
- `SUM(final_amount) OVER (PARTITION BY seller_id ORDER BY created_at)`: running revenue
- `LAG(amount) OVER (PARTITION BY auction_id ORDER BY placed_at)`: bid momentum

Every original row is kept, unlike `GROUP BY`.

---

# Feature 04 — Cursors

**`close_expired_auctions()`: the cursor lifecycle**

1. **DECLARE**: `SELECT auction_id FROM auctions WHERE end_time < now() AND status = 'ACTIVE' ORDER BY end_time FOR UPDATE`
2. **OPEN**: PostgreSQL runs the query and positions before the first row
3. **FETCH INTO rec**: one auction at a time, locked as it is fetched
4. **Process**: `UPDATE auctions SET status = 'CLOSED' WHERE CURRENT OF cur_expired`
   → `trg_close_auction` settles, then `CALL award_winner(rec.auction_id)`
5. **CLOSE**: `EXIT WHEN NOT FOUND`, close, release the locks; `REFRESH ... CONCURRENTLY`

- `FOR UPDATE` stops a late bid from slipping in between "found expired" and "closed"
- `WHERE CURRENT OF` updates the fetched row without a second lookup
- `ORDER BY end_time` matches the partial index `idx_auctions_active_end`

---

# Feature 05 — ACID transactions

| **A**tomicity | **C**onsistency | **I**solation | **D**urability |
|---|---|---|---|
| The bid, its notification and its audit row are one unit. A failure injected after the bid leaves **zero** rows behind. | `CHECK (amount > 0)`, foreign keys and the procedure's floor reject invalid bids; a negative or orphan bid cannot persist. | READ COMMITTED + `FOR UPDATE`: two simultaneous 110.00 bids, and exactly one is accepted. The other re-reads and gets AU001. | A committed bid survives `docker compose restart db`, because the write-ahead log is on disk before `COMMIT` returns. |

Proven by `db/tests/test_concurrency.sql` (7 checks, rolled back) and
`db/tests/concurrency.sh` (real concurrent sessions plus a container restart).

---

# Features 06 · 07 · 08 — Indexes, views & recursive CTE

| Composite & partial indexes | Materialized view | Recursive CTE |
|---|---|---|
| `bids (auction_id, amount DESC)`: top bid for one auction went from **2.658 ms → 0.013 ms** (Seq Scan → Index Only Scan), and the homepage grid from **3,129 ms → 16.8 ms**, at 50,446 bids. | `mv_leaderboard` stores the report: **104.9 ms → 0.58 ms** for all 5,040 auctions, and **74.3 → 0.87 ms** for the live page. | `WITH RECURSIVE cat_tree` starts at the roots (`parent_id IS NULL`) and joins children level by level, to any depth: |
| `auctions (end_time) WHERE status = 'ACTIVE'`: the close cursor **0.598 → 0.031 ms**, with an index that holds only live auctions. | A unique index on `auction_id` enables `REFRESH ... CONCURRENTLY`, so readers are never blocked. One refresh ≈ 1–2 plain reads. | **Electronics → Computers → Laptops → Gaming Laptops**. The same query serves art, cars, guitars and books; adding a level is an `INSERT`, not a migration. |

Numbers from `db/tests/benchmark.sql` (`docs/performance.md`).

---

<!-- _paginate: false -->

BIDHUB · DBMS LAB PROJECT · 2026

# Thank you

## Questions?

**10 PostgreSQL techniques**

TRIGGER · STORED PROCEDURE · CTE · WINDOW FUNCTIONS · CURSOR
RECURSIVE CTE · ACID TRANSACTION · COMPOSITE INDEX · MATERIALIZED VIEW

PL/pgSQL

ARMK SIR · DBMS LAB · TEAM OF 3
