# Performance evidence — indexes (technique 09)

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

These are not changed here (P2 doesn't edit `server/` or `client/`), but the
measurements point at them:

1. **The notification bell can't use `idx_notifications_user_unread`.** The
   header polls `GET /api/notifications`, which runs `WHERE user_id = $1` with no
   `is_read` filter and counts unread rows in JavaScript (Q7). The planner can
   only use a partial index when the query implies its `WHERE is_read = false`,
   so the bell's query stays a sequential scan: 6 ms at 100k notifications, and it
   grows with the table. A count endpoint with `AND is_read = false` would run
   at Q6's 0.012 ms.
2. **The homepage re-aggregates bids on every poll.** Q1 runs two `LATERAL`
   subqueries per live auction. With the composite index that's fine at this
   scale (17–35 ms for 515 auctions). `mv_leaderboard` (P2-05, `db/06_views.sql`)
   is the precomputed alternative.

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
