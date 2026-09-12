# Normalization

How the BidHub schema (`db/01_schema.sql`) reaches third normal form, and the few places
where it steps away from it on purpose. Table and column details are in
[data-dictionary.md](data-dictionary.md).

## Starting point: one wide "auction listing" record

Imagine the platform stored as a single spreadsheet, one row per auction:

```
listing(seller_name, seller_email, category_path, item_title, condition, ram, cpu,
        medium, mileage, …, starting_price, end_time, status,
        bid1_bidder, bid1_amount, bid2_bidder, bid2_amount, …, winner_email, final_price)
```

Everything wrong with that row is what normalization removes: repeating bid columns, a
column for every property of every domain, the seller's details repeated on every listing,
and the high bid and winner stored next to the bids they are computed from.

## First normal form: atomic values, no repeating groups

- **Bids become rows.** `bid1_…`, `bid2_…` is a repeating group, so bids move to their own
  table, `bids(bid_id, auction_id, bidder_id, amount, placed_at)`, one row per bid. An
  auction can now have any number of bids, and "the highest bid" becomes a query
  (`MAX(amount)`, served by `idx_bids_auction_amount`) rather than a column.
- **The category path becomes a relation.** A stored string such as
  `"Electronics > Computers > Laptops"` holds several values in one field. `categories`
  stores one node per row with a `parent_id`, and the path is computed on demand by the
  recursive CTE in `get_category_tree`.
- **Domain properties: `attributes` JSONB, a deliberate choice.** `ram`, `cpu`, `medium`
  and `mileage` as columns would be almost entirely NULL. Splitting them into an
  entity-attribute-value table would make every item page a pivot. Instead, each item has
  one `attributes` JSONB value. The relational model treats it as a single value of the
  item: it depends on `item_id` and nothing else. PostgreSQL can still search inside it
  (`attributes @> '{"brand":"Fender"}'`, GIN index `idx_items_attributes`). This one
  column is what lets a laptop, a painting and a car share the `items` table.

## Second normal form: every non-key column depends on the whole key

Every table except one has a single-column surrogate primary key, so a *partial*
dependency (on part of a key) can't arise.

The exception is `watchlist(user_id, auction_id, created_at)`, with the composite primary
key `(user_id, auction_id)`. Its only non-key column, `created_at`, is the moment *this
user* started watching *this auction*. It depends on both columns together, so the table
is in 2NF.

## Third normal form: no transitive dependencies

Each fact is stored once, in the table whose key determines it.

| Fact | Stored in | Not repeated in |
|---|---|---|
| seller's name and email | `users` | `items`, `auctions`, `bids` (only the id is kept) |
| item title, condition, spec | `items` | `auctions`, `bids` |
| category name | `categories` | `items` (only `category_id`) |
| current high bid, bid count | *derived*, never stored | `auctions` has no `current_bid` column |
| leading bidder | *derived* (`get_leaderboard`, `ROW_NUMBER()`) | |

Leaving out a `current_bid` column on `auctions` matters most. If it existed, every bid
would have to update it, and a failed or concurrent update could leave it disagreeing
with the `bids` table. Deriving the value makes that disagreement impossible, and the
composite index makes the derivation an index-only read.

### Why `items` and `auctions` are separate tables

`uq_auctions_item` makes the relationship one-to-one today, so merging the two tables
would be tempting. They stay apart because their columns depend on different things:

- `title`, `condition`, `attributes`, `seller_id` and `category_id` describe **the thing**
  and depend on `item_id`;
- `starting_price`, `reserve_price`, `bid_increment`, `start_time`, `end_time`, `status`
  and `winning_bid_id` describe **one attempt to sell it** and depend on `auction_id`.

In practice:

- An item can exist before it is auctioned (create the listing, then open the auction).
  A merged table would need all the auction columns nullable, and the CHECK constraints
  on prices and times would have to allow NULL.
- `place_bid` locks the auction row `FOR UPDATE` on every bid. With the tables apart, that
  lock never touches the catalog row that browse pages are reading.
- Relisting policy is explicit: a failed sale is relisted as a new item and a new auction,
  so a transaction's `item_id` always refers to exactly what was sold.

### Why `categories` references itself rather than a fixed brand/line/variant triple

The original design (LuxBid, a watch auction site) modelled the catalog as three fixed
levels: brand → line → variant. That would mean three tables (or three columns) and a
hard-coded depth of exactly three. It also bakes one domain into the schema: a painting
has no "line", and a car needs make → model → trim → year.

`categories(category_id, name, slug, parent_id → categories)` is a single relation in
which every fact about a node depends on `category_id`. Depth is data, not schema:
Electronics → Computers → Laptops → Gaming Laptops (four levels) sits beside
Books → Rare Books → First Editions (three). Adding a domain is an `INSERT`, not a
migration. This generalization is what makes the platform domain-agnostic, and the
recursive CTE (technique 07) is how it is queried.

## Controlled redundancy: where the schema steps away from 3NF on purpose

Each case below is a record of something that *happened*, which must not change when
the source rows change later.

1. **`transactions` copies `buyer_id`, `seller_id`, `item_id` and `final_amount`.** All four
   can be derived: auction → item → seller, and winning bid → bidder and amount. That is
   a transitive dependency. It is kept because a transaction is a ledger entry frozen at
   settlement. `winning_bid_id` is `ON DELETE SET NULL`, so if a bid were ever purged, a
   derived buyer would silently disappear from the books. The copies are written in
   exactly one place (`trg_close_auction`, guarded by `uq_transactions_auction`), so the
   usual update anomaly has no second writer to disagree with.

2. **`audit_log` stores the event in `payload` JSONB, with a polymorphic
   `entity_type` / `entity_id` and no foreign key.** An audit trail must describe the
   world *as it was*. It must be able to record events about any table, including rows
   later deleted, and it must never be rewritten. So each row carries its own snapshot
   (`{"bid_id", "amount", "placed_at"}`) instead of pointing at mutable rows, and
   `trg_audit_immutable` makes the table append-only. Update anomalies need updates, and
   this table refuses them.

3. **`notifications.title` and `message` are rendered text**, including the item title and
   the amount at that moment. A notification is a message that was delivered. If the
   seller later edits the title, the historical message should still read the way it
   did.

4. **`mv_leaderboard` stores a derived result**, the one place where computed values are
   persisted. It lives outside the base schema (`db/06_views.sql`), is fully rebuilt by
   `REFRESH ... CONCURRENTLY`, and is never a source of truth: anything that must be
   exact (the bid floor in `place_bid`, settlement) reads the base tables.

## Boyce–Codd

The only non-surrogate candidate keys are `users.email` (`uq_users_email`) and
`categories.slug` (`uq_categories_slug`). In both tables every determinant is a candidate
key: `user_id ↔ email` and `category_id ↔ slug` determine each other, and nothing
determines a subset of a key. Apart from the deliberate snapshots above, the base schema
is in BCNF.
