# Performance evidence — indexes (technique 09) and materialized view (technique 10)

Every number on this page comes from a real run of
[`db/tests/benchmark.sql`](../db/tests/benchmark.sql). Nothing is estimated. The
script times the platform's actual hot queries twice: once with none of the
secondary indexes, then again with exactly the definitions in
[`db/05_indexes.sql`](../db/05_indexes.sql). It loads 05 with `\ir`, so the
indexes being measured are the ones that ship. The whole script runs in one
transaction that ends in `ROLLBACK`, so you can re-run it on the demo database
and it leaves nothing behind.

```bash
psql "$DATABASE_URL" -f db/tests/benchmark.sql     # ~25 s
```

**Environment:** PostgreSQL 16.14 (`postgres:16` Docker image, default config,
`shared_buffers` = 128 MB) on Windows 11 / Docker Desktop. JIT is off for the run
because it's unrelated to indexing and adds noise. Parallel query is left at its
defaults. Each figure is the **median of 3 `EXPLAIN (ANALYZE, BUFFERS)` runs**,
taken after one warm-up execution. All reads are cache hits, so the gains shown
come from rows and pages *not visited*, not from avoided disk I/O.

## Data volume

Generated with `generate_series`, loaded on top of the seed data:

| Table | Rows | Shape |
|---|---:|---|
| `bids` | 50,426 | 100 increasing bids on each of 500 live auctions |
| `auctions` | 5,040 | 515 `ACTIVE`, the rest `CLOSED`, as on a real marketplace |
| `items` | 50,060 | 100 brands × 10 nouns; JSONB `{brand, year, colour}` |
| `categories` | 2,945 | 4-level tree: 5 roots × 8 × 8 × 8 |
| `notifications` | 100,424 | 6,424 unread (≈6%) |
| `users` | 2,020 | 200 sellers, 1,800 buyers, plus the seed users |

## Results — every index in `05_indexes.sql`

| Index | Query (where the app runs it) | Plan before → after | Time before → after (ms) | Speedup | Buffers before → after |
|---|---|---|---:|---:|---:|
| `idx_bids_auction_amount` (composite) | **Q1** Homepage grid: active auctions + high bid + bid count (`GET /api/auctions?status=ACTIVE`) | 2 × Seq Scan on `bids` per auction (515 loops) → Index Only Scan | 3129.107 → 16.772 | **186.6×** | 382,277 → 3,675 |
| `idx_bids_auction_amount` (composite) | **Q2** Top bid for one auction (`place_bid()` floor, runs on every bid) | Seq Scan → Index Only Scan + `Limit 1` | 2.658 → 0.013 | **204.5×** | 371 → 3 |
| `idx_bids_auction_amount` (composite) | Q3 Leading bid with tie-break (`trg_close_auction`, `award_winner`, `trg_outbid`) | Seq Scan → Index Scan | 3.297 → 0.014 | 235.5× | 371 → 3 |
| `idx_auctions_active_end` (partial) | **Q5** Expired-auction cursor (`close_expired_auctions()`) | Seq Scan → Bitmap Index Scan | 0.598 → 0.031 | 19.3× | 58 → 4 |
| `idx_auctions_active_end` (partial) | Q1 Homepage grid (the `status = 'ACTIVE'` half) | Seq Scan (4,525 rows filtered out) → Bitmap Index Scan | *(inside Q1)* | — | — |
| `idx_bids_bidder_placed` | **Q4** My bids history (`GET /api/me/bids`) | Seq Scan → Bitmap Index Scan | 4.625 → 0.221 | 20.9× | 471 → 132 |
| `idx_notifications_user_unread` (partial) | Q6 Unread notifications for one user | Seq Scan → Bitmap Index Scan | 10.243 → 0.012 | 853.6× | 1,342 → 5 |
| `idx_items_category` | Q9 Items in a category subtree (`GET /api/items?category=`) | Seq Scan on `items` → Index Scan | 10.888 → 1.227 | 8.9× | 1,295 → 252 |
| `idx_categories_parent` | Q8 Category tree, recursive CTE (`get_category_tree()`) | Seq Scan per level → Index Scan per level | 6.104 → 4.230 | 1.4× | 127 → 1,250 |
| `idx_items_seller` | Q10 Items by seller (`GET /api/items?seller=`) | Seq Scan → Bitmap Index Scan | 4.485 → 1.081 | 4.1× | 1,209 → 286 |
| `idx_items_title_trgm` (GIN) | Q11 Keyword search, `title ILIKE '%zenpex%'` (`GET /api/items?q=`) | Seq Scan → Bitmap Index Scan | 39.702 → 2.921 | 13.6× | 1,211 → 83 |
| `idx_items_attributes` (GIN) | Q12 JSONB search, `attributes @> '{"brand":"Kamela","year":"1990"}'` | Seq Scan → Bitmap Index Scan | 13.433 → 0.048 | 279.9× | 1,175 → 8 |
| *(none applies)* | Q7 Notification list as the route runs it today (`GET /api/notifications`) | Seq Scan → Seq Scan | 6.010 → 6.690 | 0.9× | 1,342 → 1,342 |

Planning time was under 1 ms for every query in both runs, so the index choice
itself costs nothing measurable.

### What each index changed

- **`idx_bids_auction_amount`:** each auction's bids are stored pre-sorted by
  `amount DESC`, so `MAX(amount)` becomes "read the first index entry": 3 buffers
  instead of all 371 pages of `bids`. On the homepage that happens once per live
  auction, which is how 382,277 buffer visits became 3,675.
- **`idx_auctions_active_end`:** the close-job cursor and the homepage stop
  reading 4,500+ closed auctions just to discard them. The index contains only the
  515 live rows.
- **`idx_bids_bidder_placed`:** the 30 bids of one user are found directly
  instead of filtering out 50,396 other rows. The final `ORDER BY placed_at DESC`
  is still a 30-row Sort, because the planner prefers a bitmap scan feeding a
  merge join. The index order would take over for longer histories or a `LIMIT`.
- **`idx_notifications_user_unread`:** a user's 3 unread rows come straight from
  a 120 kB partial index instead of a scan of 100k notifications.
- **`idx_items_category`:** the 9 category ids from the recursive CTE are
  looked up in the index instead of a full scan of 50k items.
- **`idx_categories_parent`:** each recursion level fetches "children of these
  parents" by index instead of scanning the whole table. At 2,945 categories the
  win is small (1.4×), and buffer hits actually *rise*, because index probes
  touch more pages than one pass over a small table. The gain grows with tree
  size. The index also backs the `ON DELETE RESTRICT` check on
  `fk_categories_parent`.
- **`idx_items_seller`:** one seller's ~250 items are fetched through a bitmap
  instead of a scan of 50k rows.
- **`idx_items_title_trgm`:** a B-tree can't serve a leading-wildcard `ILIKE`.
  The trigram index finds the candidate titles containing every 3-letter chunk of
  the search term, then rechecks only those.
- **`idx_items_attributes`:** JSONB containment is answered from the GIN index
  (8 buffers), which keeps the domain-agnostic `attributes` column searchable.
  It's `jsonb_path_ops`, which is smaller than the default operator class because
  it supports only `@>`.

## The partial indexes really are smaller

The benchmark also builds, inside the rolled-back transaction, the full
(non-partial) version of each partial index for comparison:

| Index | Rows indexed | Size |
|---|---:|---:|
| `idx_auctions_active_end` — `WHERE status = 'ACTIVE'` | 515 of 5,040 | **32 kB** |
| full `auctions (end_time)` for comparison | 5,040 | 128 kB |
| `idx_notifications_user_unread` — `WHERE is_read = false` | 6,424 of 100,424 | **120 kB** |
| full `notifications (user_id)` for comparison | 100,424 | 720 kB |

The partial indexes are 4× and 6× smaller. A real marketplace keeps accumulating
closed auctions and read notifications, so the full versions would keep growing
while the partial ones stay roughly the size of the *live* data.

Sizes of the remaining indexes at this data volume: `idx_bids_auction_amount`
1,568 kB · `idx_bids_bidder_placed` 1,560 kB · `idx_items_category` 408 kB ·
`idx_items_seller` 376 kB · `idx_items_attributes` 336 kB ·
`idx_items_title_trgm` 3,440 kB · `idx_categories_parent` 48 kB.

## Reproducibility and caveats

A second, independent run gave the same plan choice for every query and
near-identical buffer counts. Times moved by up to about 2× in the fast
sub-millisecond-to-tens-of-ms range, which is ordinary timer and scheduler noise
at that scale:

| Run 2 | Q1 | Q2 | Q3 | Q4 | Q5 | Q6 | Q7 | Q8 | Q9 | Q10 | Q11 | Q12 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| before (ms) | 3177.387 | 3.584 | 3.852 | 4.089 | 0.485 | 7.808 | 8.250 | 5.896 | 13.601 | 5.674 | 40.218 | 13.233 |
| after (ms) | 34.636 | 0.013 | 0.010 | 0.367 | 0.033 | 0.012 | 5.784 | 4.097 | 1.179 | 1.035 | 1.928 | 0.050 |

- **Trust the plans and the buffer counts over the milliseconds.** They're
  deterministic. The one buffer count that changed between runs was Q11: 83 in
  run 1, 1,834 in run 2. The trigram bitmap scan was identical both times; only
  the joins to `categories`/`users` switched from Seq Scan to nested-loop PK
  lookups, after a slightly different `ANALYZE` sample.
- **Index-only scans still visit the heap here** (`Heap Fetches: 515` in Q1).
  The synthetic rows are never committed, so `VACUUM` never sets the visibility
  map. On a vacuumed production table the "after" numbers would be the same or
  better.
- **Warm cache only.** On a cold cache every "before" column would get worse,
  because a sequential scan reads every page from disk.

## Findings for the application layer

These were not changed on this branch (P2 doesn't edit `server/` or `client/`),
but the measurements pointed at them:

1. **The notification bell couldn't use `idx_notifications_user_unread`.** The
   header polled `GET /api/notifications`, which runs `WHERE user_id = $1` with no
   `is_read` filter, and counted unread rows in JavaScript (Q7). The planner can
   only use a partial index when the query implies its `WHERE is_read = false`,
   so the bell's query stayed a sequential scan: 6 ms at 100k notifications, and it
   grows with the table. A count endpoint with `AND is_read = false` runs at Q6's
   0.012 ms.
   **Resolved in INT-01:** `GET /api/notifications/unread-count` runs exactly Q6's
   predicate, and the header bell now polls it instead of the full list.
2. **The homepage re-aggregates bids on every poll.** Q1 runs two `LATERAL`
   subqueries per live auction. With the composite index that's fine at this
   scale (17–35 ms for 515 auctions). `mv_leaderboard` (P2-05, `db/06_views.sql`)
   is the precomputed alternative. See
   [Plain view vs materialized view](#plain-view-vs-materialized-view-technique-10).

<details>
<summary><b>Full EXPLAIN (ANALYZE, BUFFERS) — the four headline queries, run 1</b></summary>

These are the text plans from the run above. Each was captured in one extra
execution after the three timed runs, so its execution time can differ slightly
from the median in the table.

**Q1 Homepage — BEFORE**
```
Nested Loop Left Join  (cost=3401.61..1033085.87 rows=515 width=161) (actual time=11.951..3188.996 rows=515 loops=1)
  Buffers: shared hit=382277
  ->  Nested Loop Left Join  (cost=2400.05..517270.89 rows=515 width=157) (actual time=8.922..1621.274 rows=515 loops=1)
        Buffers: shared hit=191212
        ->  Gather Merge  (cost=1398.49..1457.19 rows=515 width=125) (actual time=5.830..7.032 rows=515 loops=1)
              Workers Planned: 1
              Workers Launched: 1
              Buffers: shared hit=147
              ->  Sort  (cost=398.48..399.24 rows=303 width=125) (actual time=1.021..1.289 rows=258 loops=2)
                    Sort Key: a.end_time
                    Sort Method: quicksort  Memory: 89kB
                    Buffers: shared hit=147
                    Worker 0:  Sort Method: quicksort  Memory: 25kB
                    ->  Merge Join  (cost=144.49..385.99 rows=303 width=125) (actual time=0.657..0.877 rows=258 loops=2)
                          Merge Cond: (i.item_id = a.item_id)
                          Buffers: shared hit=139
                          ->  Parallel Index Scan using items_pkey on items i  (cost=0.29..2279.06 rows=29447 width=74) (actual time=0.014..0.073 rows=281 loops=2)
                                Buffers: shared hit=19
                          ->  Sort  (cost=144.20..145.48 rows=515 width=55) (actual time=0.609..0.639 rows=515 loops=2)
                                Sort Key: a.item_id
                                Sort Method: quicksort  Memory: 69kB
                                Buffers: shared hit=120
                                Worker 0:  Sort Method: quicksort  Memory: 69kB
                                ->  Seq Scan on auctions a  (cost=0.00..121.00 rows=515 width=55) (actual time=0.012..0.544 rows=515 loops=2)
                                      Filter: (status = 'ACTIVE'::auction_status)
                                      Rows Removed by Filter: 4525
                                      Buffers: shared hit=116
        ->  Aggregate  (cost=1001.56..1001.57 rows=1 width=32) (actual time=3.129..3.130 rows=1 loops=515)
              Buffers: shared hit=191065
              ->  Seq Scan on bids  (cost=0.00..1001.33 rows=94 width=5) (actual time=1.551..3.105 rows=97 loops=515)
                    Filter: (auction_id = a.auction_id)
                    Rows Removed by Filter: 50329
                    Buffers: shared hit=191065
  ->  Aggregate  (cost=1001.56..1001.57 rows=1 width=8) (actual time=3.039..3.039 rows=1 loops=515)
        Buffers: shared hit=191065
        ->  Seq Scan on bids bids_1  (cost=0.00..1001.33 rows=94 width=0) (actual time=1.502..3.024 rows=97 loops=515)
              Filter: (auction_id = a.auction_id)
              Rows Removed by Filter: 50329
              Buffers: shared hit=191065
Planning:
  Buffers: shared hit=9
Planning Time: 0.380 ms
Execution Time: 3189.683 ms
```

**Q1 Homepage — AFTER**
```
Sort  (cost=81462.27..81463.56 rows=515 width=161) (actual time=16.790..16.816 rows=515 loops=1)
  Sort Key: a.end_time
  Sort Method: quicksort  Memory: 94kB
  Buffers: shared hit=3675
  ->  Nested Loop Left Join  (cost=264.26..81439.08 rows=515 width=161) (actual time=0.175..16.556 rows=515 loops=1)
        Buffers: shared hit=3675
        ->  Nested Loop Left Join  (cost=108.84..1386.19 rows=515 width=157) (actual time=0.162..3.441 rows=515 loops=1)
              Buffers: shared hit=1572
              ->  Merge Join  (cost=106.90..376.62 rows=515 width=125) (actual time=0.150..0.556 rows=515 loops=1)
                    Merge Cond: (i.item_id = a.item_id)
                    Buffers: shared hit=27
                    ->  Index Scan using items_pkey on items i  (cost=0.29..2485.19 rows=50060 width=74) (actual time=0.006..0.111 rows=561 loops=1)
                          Buffers: shared hit=17
                    ->  Sort  (cost=106.61..107.90 rows=515 width=55) (actual time=0.139..0.177 rows=515 loops=1)
                          Sort Key: a.item_id
                          Sort Method: quicksort  Memory: 69kB
                          Buffers: shared hit=10
                          ->  Bitmap Heap Scan on auctions a  (cost=18.98..83.42 rows=515 width=55) (actual time=0.025..0.086 rows=515 loops=1)
                                Recheck Cond: (status = 'ACTIVE'::auction_status)
                                Heap Blocks: exact=7
                                Buffers: shared hit=10
                                ->  Bitmap Index Scan on idx_auctions_active_end  (cost=0.00..18.85 rows=515 width=0) (actual time=0.018..0.019 rows=515 loops=1)
                                      Buffers: shared hit=3
              ->  Result  (cost=1.94..1.95 rows=1 width=32) (actual time=0.005..0.005 rows=1 loops=515)
                    Buffers: shared hit=1545
                    InitPlan 1 (returns $1)
                      ->  Limit  (cost=0.29..1.94 rows=1 width=5) (actual time=0.005..0.005 rows=1 loops=515)
                            Buffers: shared hit=1545
                            ->  Index Only Scan using idx_bids_auction_amount on bids bids_1  (cost=0.29..155.42 rows=94 width=5) (actual time=0.005..0.005 rows=1 loops=515)
                                  Index Cond: ((auction_id = a.auction_id) AND (amount IS NOT NULL))
                                  Heap Fetches: 515
                                  Buffers: shared hit=1545
        ->  Aggregate  (cost=155.42..155.43 rows=1 width=8) (actual time=0.025..0.025 rows=1 loops=515)
              Buffers: shared hit=2103
              ->  Index Only Scan using idx_bids_auction_amount on bids  (cost=0.29..155.19 rows=94 width=0) (actual time=0.004..0.019 rows=97 loops=515)
                    Index Cond: (auction_id = a.auction_id)
                    Heap Fetches: 50199
                    Buffers: shared hit=2103
Planning:
  Buffers: shared hit=9
Planning Time: 0.365 ms
Execution Time: 16.899 ms
```

**Q2 Top bid for one auction — BEFORE**
```
Aggregate  (cost=1001.56..1001.57 rows=1 width=32) (actual time=3.215..3.216 rows=1 loops=1)
  Buffers: shared hit=371
  ->  Seq Scan on bids b  (cost=0.00..1001.33 rows=92 width=5) (actual time=1.652..3.195 rows=100 loops=1)
        Filter: (auction_id = 291)
        Rows Removed by Filter: 50326
        Buffers: shared hit=371
Planning Time: 0.071 ms
Execution Time: 3.231 ms
```

**Q2 Top bid for one auction — AFTER**
```
Result  (cost=1.96..1.97 rows=1 width=32) (actual time=0.008..0.009 rows=1 loops=1)
  Buffers: shared hit=3
  InitPlan 1 (returns $0)
    ->  Limit  (cost=0.29..1.96 rows=1 width=5) (actual time=0.008..0.008 rows=1 loops=1)
          Buffers: shared hit=3
          ->  Index Only Scan using idx_bids_auction_amount on bids b  (cost=0.29..151.86 rows=91 width=5) (actual time=0.007..0.007 rows=1 loops=1)
                Index Cond: ((auction_id = 291) AND (amount IS NOT NULL))
                Heap Fetches: 1
                Buffers: shared hit=3
Planning Time: 0.040 ms
Execution Time: 0.015 ms
```

**Q4 My bids history — BEFORE**
```
Sort  (cost=1064.10..1064.17 rows=28 width=72) (actual time=3.982..3.986 rows=30 loops=1)
  Sort Key: b.placed_at DESC
  Sort Method: quicksort  Memory: 28kB
  Buffers: shared hit=471
  ->  Nested Loop  (cost=1002.57..1063.42 rows=28 width=72) (actual time=3.769..3.964 rows=30 loops=1)
        Buffers: shared hit=471
        ->  Merge Join  (cost=1002.28..1025.54 rows=28 width=41) (actual time=3.754..3.891 rows=30 loops=1)
              Merge Cond: (a.auction_id = b.auction_id)
              Buffers: shared hit=381
              ->  Index Scan using auctions_pkey on auctions a  (cost=0.28..200.88 rows=5040 width=24) (actual time=0.005..0.092 rows=537 loops=1)
                    Buffers: shared hit=10
              ->  Sort  (cost=1002.00..1002.07 rows=28 width=21) (actual time=3.726..3.729 rows=30 loops=1)
                    Sort Key: b.auction_id
                    Sort Method: quicksort  Memory: 26kB
                    Buffers: shared hit=371
                    ->  Seq Scan on bids b  (cost=0.00..1001.33 rows=28 width=21) (actual time=0.042..3.714 rows=30 loops=1)
                          Filter: (bidder_id = 923)
                          Rows Removed by Filter: 50396
                          Buffers: shared hit=371
        ->  Index Scan using items_pkey on items i  (cost=0.29..1.35 rows=1 width=38) (actual time=0.002..0.002 rows=1 loops=30)
              Index Cond: (item_id = a.item_id)
              Buffers: shared hit=90
Planning:
  Buffers: shared hit=12
Planning Time: 0.344 ms
Execution Time: 4.025 ms
```

**Q4 My bids history — AFTER**
```
Sort  (cost=153.78..153.85 rows=28 width=72) (actual time=0.225..0.227 rows=30 loops=1)
  Sort Key: b.placed_at DESC
  Sort Method: quicksort  Memory: 28kB
  Buffers: shared hit=132
  ->  Nested Loop  (cost=92.25..153.10 rows=28 width=72) (actual time=0.046..0.215 rows=30 loops=1)
        Buffers: shared hit=132
        ->  Merge Join  (cost=91.96..115.22 rows=28 width=41) (actual time=0.043..0.171 rows=30 loops=1)
              Merge Cond: (a.auction_id = b.auction_id)
              Buffers: shared hit=42
              ->  Index Scan using auctions_pkey on auctions a  (cost=0.28..200.88 rows=5040 width=24) (actual time=0.003..0.067 rows=537 loops=1)
                    Buffers: shared hit=10
              ->  Sort  (cost=91.68..91.75 rows=28 width=21) (actual time=0.029..0.032 rows=30 loops=1)
                    Sort Key: b.auction_id
                    Sort Method: quicksort  Memory: 26kB
                    Buffers: shared hit=32
                    ->  Bitmap Heap Scan on bids b  (cost=4.51..91.01 rows=28 width=21) (actual time=0.008..0.024 rows=30 loops=1)
                          Recheck Cond: (bidder_id = 923)
                          Heap Blocks: exact=30
                          Buffers: shared hit=32
                          ->  Bitmap Index Scan on idx_bids_bidder_placed  (cost=0.00..4.50 rows=28 width=0) (actual time=0.004..0.004 rows=30 loops=1)
                                Index Cond: (bidder_id = 923)
                                Buffers: shared hit=2
        ->  Index Scan using items_pkey on items i  (cost=0.29..1.35 rows=1 width=38) (actual time=0.001..0.001 rows=1 loops=30)
              Index Cond: (item_id = a.item_id)
              Buffers: shared hit=90
Planning:
  Buffers: shared hit=18
Planning Time: 0.202 ms
Execution Time: 0.247 ms
```

**Q5 Expired-auction cursor — BEFORE**
```
Sort  (cost=166.91..168.07 rows=467 width=16) (actual time=0.602..0.606 rows=49 loops=1)
  Sort Key: end_time
  Sort Method: quicksort  Memory: 26kB
  Buffers: shared hit=58
  ->  Seq Scan on auctions  (cost=0.00..146.20 rows=467 width=16) (actual time=0.011..0.591 rows=49 loops=1)
        Filter: ((status = 'ACTIVE'::auction_status) AND (end_time < now()))
        Rows Removed by Filter: 4991
        Buffers: shared hit=58
Planning Time: 0.058 ms
Execution Time: 0.619 ms
```

**Q5 Expired-auction cursor — AFTER**
```
Sort  (cost=106.77..107.94 rows=467 width=16) (actual time=0.018..0.021 rows=49 loops=1)
  Sort Key: end_time
  Sort Method: quicksort  Memory: 26kB
  Buffers: shared hit=4
  ->  Bitmap Heap Scan on auctions  (cost=19.90..86.07 rows=467 width=16) (actual time=0.005..0.011 rows=49 loops=1)
        Recheck Cond: ((end_time < now()) AND (status = 'ACTIVE'::auction_status))
        Heap Blocks: exact=2
        Buffers: shared hit=4
        ->  Bitmap Index Scan on idx_auctions_active_end  (cost=0.00..19.78 rows=467 width=0) (actual time=0.003..0.003 rows=49 loops=1)
              Index Cond: (end_time < now())
              Buffers: shared hit=2
Planning Time: 0.027 ms
Execution Time: 0.030 ms
```

</details>

---

## Plain view vs materialized view (technique 10)

Measured by section 9 of `db/tests/benchmark.sql`, on the same synthetic data
(5,040 auctions, 50,446 bids) with the indexes from `05_indexes.sql` in place.
In [`db/06_views.sql`](../db/06_views.sql), `mv_leaderboard` is defined as
`SELECT * FROM v_auction_summary`, so both sides run **the same query**. The plain
view recomputes it on every read. The materialized view returns the result
stored at its last `REFRESH`. `db/tests/test_views.sql` asserts that the two are
identical right after a refresh.

| Read | Plain view `v_auction_summary` (ms) | Materialized `mv_leaderboard` (ms) | Speedup | Buffers plain → matview |
|---|---:|---:|---:|---:|
| Full report: all 5,040 auctions | 104.910 | 0.578 | **181.5×** | 3,021 → 128 |
| Live auctions page: `WHERE status = 'ACTIVE' ORDER BY end_time` (515 rows) | 74.263 | 0.865 | **85.9×** | 4,355 → 128 |
| One auction by id (live auction page) | 0.196 | 0.008 | 24.5× | 21 → 3 |
| *Reference:* lean plain view `v_active_auctions` (fewer columns, one `LATERAL` probe per auction) | 23.208 | — | — | 2,194 |

The other side of the trade-off is what a refresh costs. These are medians of 3,
measured with nothing changed between refreshes:

| Refresh | Time (ms) | Lock held | Readers during refresh |
|---|---:|---|---|
| `REFRESH MATERIALIZED VIEW` | 135.118 | `ACCESS EXCLUSIVE` | blocked until it finishes |
| `REFRESH MATERIALIZED VIEW CONCURRENTLY` | 141.593 | `EXCLUSIVE` | keep reading the old snapshot |

`mv_leaderboard` holds 5,040 rows in 1,168 kB, including `uq_mv_leaderboard_auction`.

### What this shows

- **The plain view pays for the whole computation on every read:** a
  `WindowAgg` computing `ROW_NUMBER()` over all 50,446 bids, a `GroupAggregate`
  for `COUNT(DISTINCT bidder_id)`, and five joins. The materialized view's read
  is a 128-page scan of rows that are already finished (plans below).
- **Break-even is about 1–2 reads per refresh.** One refresh costs about as
  much as 1.3 full-report reads (135 / 104.9) or 1.8 live-page reads
  (135 / 74.3). A page polled every 5 seconds by even one viewer makes 12 reads a
  minute. Refreshed once a minute, the materialized view does one refresh's work
  where the plain view would recompute 12 times, and every additional viewer
  widens the gap.
- **For a single row the plain view is already fast.** PostgreSQL pushes
  `auction_id = N` down into the view's CTEs (it's the `ROW_NUMBER()` partition
  key and the `GROUP BY` key), and `idx_bids_auction_amount` serves it: 21 buffers,
  not the 1,072 pages of `bids`. The materialized view pays off on
  **multi-row** reads such as reports and grids, not on point lookups.
- **The price is freshness.** `mv_leaderboard` is as current as its last
  refresh. It's refreshed by every run of `close_expired_auctions()` (the close
  job) and by `CALL refresh_leaderboard()`. Check 5 of `test_views.sql` shows
  it: a new bid appears in the plain views at once, and in `mv_leaderboard` only
  after the refresh. Anything that must be current (a bidder's own confirmation,
  `place_bid()`'s floor) reads the base tables, never the snapshot.
- **`CONCURRENTLY` is slightly slower** because it diffs the new result against
  the old one by the unique key. In exchange, readers are never blocked.
  Without `uq_mv_leaderboard_auction`, PostgreSQL refuses it outright with
  `SQLSTATE 55000` (check 6 of `test_views.sql`). The diff work grows with the
  number of rows that changed since the last refresh.

Today the API reads neither view: the homepage runs its own query (Q1 above).
Pointing the homepage and the live-auction report at `mv_leaderboard` would be a
P3 change in `server/`.

<details>
<summary><b>EXPLAIN (ANALYZE, BUFFERS) — full report, plain view vs materialized view</b></summary>

Captured in one extra execution after the timed runs. This plain-view run took
74.0 ms against the 104.9 ms median, which is the same run-to-run noise noted
above.

**Plain view `SELECT * FROM v_auction_summary`**
```
Nested Loop  (cost=5849.73..11801.81 rows=5040 width=145) (actual time=39.958..73.716 rows=5040 loops=1)
  Buffers: shared hit=3021
  ->  Hash Left Join  (cost=5849.44..11488.57 rows=5040 width=119) (actual time=39.917..69.092 rows=5040 loops=1)
        Hash Cond: (a.auction_id = bs.auction_id)
        Buffers: shared hit=2406
        ->  Hash Join  (cost=757.44..6383.32 rows=5040 width=103) (actual time=6.360..34.555 rows=5040 loops=1)
              Hash Cond: (i.category_id = c.category_id)
              Buffers: shared hit=1334
              ->  Hash Right Join  (cost=660.18..6272.81 rows=5040 width=83) (actual time=5.583..32.247 rows=5040 loops=1)
                    Hash Cond: (lb.auction_id = a.auction_id)
                    Buffers: shared hit=1303
                    ->  Hash Left Join  (cost=70.38..5679.55 rows=252 width=24) (actual time=1.621..27.071 rows=535 loops=1)
                          Hash Cond: (lb.bidder_id = hb.user_id)
                          Buffers: shared hit=1096
                          ->  Subquery Scan on lb  (cost=0.93..5609.44 rows=252 width=13) (actual time=0.035..25.220 rows=535 loops=1)
                                Filter: (lb."position" = 1)
                                Buffers: shared hit=1072
                                ->  WindowAgg  (cost=0.93..4978.86 rows=50446 width=29) (actual time=0.034..25.132 rows=535 loops=1)
                                      Run Condition: (row_number() OVER (?) <= 1)
                                      Buffers: shared hit=1072
                                      ->  Incremental Sort  (cost=0.93..3969.94 rows=50446 width=21) (actual time=0.028..21.134 rows=50446 loops=1)
                                            Sort Key: b.auction_id, b.amount DESC, b.placed_at
                                            Presorted Key: b.auction_id, b.amount
                                            Full-sort Groups: 1577  Sort Method: quicksort  Average Memory: 26kB  Peak Memory: 26kB
                                            Buffers: shared hit=1072
                                            ->  Index Scan using idx_bids_auction_amount on bids b  (cost=0.29..2400.61 rows=50446 width=21) (actual time=0.008..8.854 rows=50446 loops=1)
                                                  Buffers: shared hit=1072
                          ->  Hash  (cost=44.20..44.20 rows=2020 width=19) (actual time=1.579..1.580 rows=2020 loops=1)
                                Buckets: 2048  Batches: 1  Memory Usage: 119kB
                                Buffers: shared hit=24
                                ->  Seq Scan on users hb  (cost=0.00..44.20 rows=2020 width=19) (actual time=0.008..0.685 rows=2020 loops=1)
                                      Buffers: shared hit=24
                    ->  Hash  (cost=526.79..526.79 rows=5040 width=63) (actual time=3.955..3.957 rows=5040 loops=1)
                          Buckets: 8192  Batches: 1  Memory Usage: 568kB
                          Buffers: shared hit=207
                          ->  Merge Join  (cost=0.61..526.79 rows=5040 width=63) (actual time=0.014..2.972 rows=5040 loops=1)
                                Merge Cond: (a.item_id = i.item_id)
                                Buffers: shared hit=207
                                ->  Index Scan using uq_auctions_item on auctions a  (cost=0.28..200.88 rows=5040 width=25) (actual time=0.006..0.717 rows=5040 loops=1)
                                      Buffers: shared hit=73
                                ->  Index Scan using items_pkey on items i  (cost=0.29..2485.19 rows=50060 width=46) (actual time=0.004..0.688 rows=5060 loops=1)
                                      Buffers: shared hit=134
              ->  Hash  (cost=60.45..60.45 rows=2945 width=28) (actual time=0.771..0.772 rows=2945 loops=1)
                    Buckets: 4096  Batches: 1  Memory Usage: 215kB
                    Buffers: shared hit=31
                    ->  Seq Scan on categories c  (cost=0.00..60.45 rows=2945 width=28) (actual time=0.009..0.335 rows=2945 loops=1)
                          Buffers: shared hit=31
        ->  Hash  (cost=5085.32..5085.32 rows=535 width=20) (actual time=33.549..33.551 rows=535 loops=1)
              Buckets: 1024  Batches: 1  Memory Usage: 36kB
              Buffers: shared hit=1072
              ->  Subquery Scan on bs  (cost=7.87..5085.32 rows=535 width=20) (actual time=0.036..33.425 rows=535 loops=1)
                    Buffers: shared hit=1072
                    ->  GroupAggregate  (cost=7.87..5079.97 rows=535 width=20) (actual time=0.035..33.340 rows=535 loops=1)
                          Group Key: bids.auction_id
                          Buffers: shared hit=1072
                          ->  Incremental Sort  (cost=7.87..4696.27 rows=50446 width=8) (actual time=0.026..27.117 rows=50446 loops=1)
                                Sort Key: bids.auction_id, bids.bidder_id
                                Presorted Key: bids.auction_id
                                Full-sort Groups: 511  Sort Method: quicksort  Average Memory: 26kB  Peak Memory: 26kB
                                Pre-sorted Groups: 501  Sort Method: quicksort  Average Memory: 25kB  Peak Memory: 25kB
                                Buffers: shared hit=1072
                                ->  Index Scan using idx_bids_auction_amount on bids  (cost=0.29..2400.61 rows=50446 width=8) (actual time=0.005..8.461 rows=50446 loops=1)
                                      Buffers: shared hit=1072
  ->  Memoize  (cost=0.29..0.31 rows=1 width=19) (actual time=0.000..0.000 rows=1 loops=5040)
        Cache Key: i.seller_id
        Cache Mode: logical
        Hits: 4835  Misses: 205  Evictions: 0  Overflows: 0  Memory Usage: 25kB
        Buffers: shared hit=615
        ->  Index Scan using users_pkey on users s  (cost=0.28..0.30 rows=1 width=19) (actual time=0.001..0.001 rows=1 loops=205)
              Index Cond: (user_id = i.seller_id)
              Buffers: shared hit=615
Planning:
  Buffers: shared hit=45
Planning Time: 2.212 ms
Execution Time: 74.043 ms
```

**Materialized view `SELECT * FROM mv_leaderboard`**
```
Seq Scan on mv_leaderboard  (cost=0.00..178.40 rows=5040 width=131) (actual time=0.001..0.328 rows=5040 loops=1)
  Buffers: shared hit=128
Planning Time: 0.012 ms
Execution Time: 0.524 ms
```

Note that the composite index from 05 helps even the plain view: it feeds the
window function bids already ordered by `(auction_id, amount DESC)`, so only an
*incremental* sort on `placed_at` is left.

</details>
