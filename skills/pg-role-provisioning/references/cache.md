# The `<app>_cache` database

`create-application-databases.sh` provisions a third database next to
`<app>` and `<app>_dbos`, named:

```
<app>_cache
```

It gets the same namespace roles and the same application schema as the
application database, plus two things nothing else in the toolkit gets:
an **`UNLOGGED` `cache` table** and **`synchronous_commit = off` on the
database**. Pass `-k` to `create-application-databases.sh` to skip it.

---

## Why a separate database

Both optimisations are what make a Postgres cache competitive, and
neither can be scoped to a table:

| Optimisation | Scope | Consequence |
| --- | --- | --- |
| `UNLOGGED` | per table | Table contents aren't WAL-logged. |
| `synchronous_commit = off` | per **database** / role / transaction | Commits don't wait for an fsync. |

`synchronous_commit` has no table-level setting. Turning it off for a
cache table that lives in `<app>` would turn it off for every order,
payment and audit row in `<app>` too. A dedicated database is what
confines "the last few hundred milliseconds of writes can vanish on a
crash" to data that is disposable by definition.

The two settings are **not** redundant with each other. An unlogged
table writes no WAL for its *data*, but a write transaction still
assigns a transaction ID and writes a commit record — and that record is
fsynced unless `synchronous_commit` is off. You want both.

The cost of the separation: `<app>_cache` is a different database, so it
needs **its own connection/pool**, and there are no cross-database
joins or transactions. See "Invalidation is best-effort" below.

---

## The table

Created by `setup-database-roles.pgsql.sql` when
`create_cache_table=true` — not by application migrations, because none
of the four permission roles has `CREATE` on the schema:

```sql
CREATE UNLOGGED TABLE cache (
    key        text        PRIMARY KEY,
    value      jsonb       NOT NULL,
    expires_at timestamptz NOT NULL
) WITH (
    fillfactor = 70,
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_vacuum_cost_delay = 0
);

CREATE INDEX cache_expires_at_idx ON cache (expires_at);

ALTER DATABASE <app>_cache SET synchronous_commit = off;
```

It lands in the application schema (`-s`, default `<namespace>`), and
the database `search_path` points there, so unqualified `cache` resolves
for application and developer sessions alike.

The `expires_at` index serves the **expiry sweep**, not reads: a lookup
is a primary-key probe on `key` that filters `expires_at` from the row
it already fetched.

Grants come from the normal role model — all four tiers get their usual
DML on it, plus `TRUNCATE` on `cache` for `<namespace>_application` and
`<namespace>_developer` specifically (`TRUNCATE` is not part of the DML
the grant blocks hand out, and it is the right way to flush a cache).
The read-only tiers can read the cache but cannot sweep or flush it.

---

## Query patterns

### Set (upsert with TTL)

```sql
INSERT INTO cache (key, value, expires_at)
VALUES ($1, $2, now() + make_interval(secs => $3))
ON CONFLICT (key) DO UPDATE
SET value      = EXCLUDED.value,
    expires_at = EXCLUDED.expires_at;
```

`make_interval(secs => $3)` keeps the TTL a bound parameter; for a fixed
TTL, `now() + interval '60 seconds'` is equivalent and cheaper to read.

### Get

```sql
SELECT value FROM cache WHERE key = $1 AND expires_at > now();
```

The `expires_at > now()` filter is **mandatory**, not an optimisation:
the sweep below is lazy, so expired rows are readable until it runs.

`now()` is transaction-start time, not statement time. In autocommit
that is exactly right. Inside a long-running transaction it freezes, so
a transaction open for a minute will treat entries that expired during
it as live; use `clock_timestamp()` there if that matters.

### Invalidate one key / a prefix

```sql
DELETE FROM cache WHERE key = $1;
DELETE FROM cache WHERE key LIKE $1 || '%';
```

The prefix form only uses the primary-key index when the database
collation is `C`. Under any other collation a btree on `text` cannot
answer `LIKE 'prefix%'`, and this becomes a sequential scan — add
`CREATE INDEX ON cache (key text_pattern_ops)` if you rely on it.

### Sweep expired entries

Run it on a schedule (a DBOS scheduled workflow, cron, pg_cron).
Batched, so it never becomes one long transaction holding dead tuples
back:

```sql
DELETE FROM cache c
USING (
    SELECT key FROM cache
    WHERE expires_at <= now()
    ORDER BY expires_at
    LIMIT 10000
    FOR UPDATE SKIP LOCKED
) expired
WHERE c.key = expired.key;
```

`FOR UPDATE SKIP LOCKED` lets several sweepers (or a sweeper and a
concurrent upsert of the same key) run without blocking each other.
Loop until it reports 0 rows.

### Flush everything

```sql
TRUNCATE cache;
```

Far cheaper than `DELETE FROM cache`, and it reclaims the space
immediately instead of leaving it for autovacuum.

### Inspect

```sql
SELECT count(*) FILTER (WHERE expires_at > now()) AS live,
       count(*)                                   AS total,
       pg_size_pretty(pg_total_relation_size('cache')) AS size;
```

A `total` that stays far above `live` means the sweep isn't keeping up.

---

## Trade-offs to know before relying on this

**Rows vanish on a crash.** `UNLOGGED` means PostgreSQL truncates the
table during crash recovery. A *clean* shutdown and restart keeps the
rows; an OOM kill, a power loss or an immediate-mode stop does not.
Treat a miss on a key you just wrote as a normal outcome — code that
assumes read-after-write will work most of the time and then fail at the
worst moment.

**Unlogged tables don't replicate.** The contents never reach a physical
standby, and the relation is not readable there at all. Don't point
read replicas at the cache database.

**`synchronous_commit = off` loses recent commits, not integrity.** The
window is roughly `3 × wal_writer_delay` (≈600 ms at the default). No
corruption, no torn rows — just the most recent cache writes. Also note
it is a *database* setting: an `ALTER ROLE ... SET synchronous_commit`
on the login role **outranks** it. If cache writes look slower than
expected, check `\drds`.

**Every refresh of a live key is a non-HOT update.** A HOT update
requires that no indexed column change, and an upsert rewrites
`expires_at`, which is indexed. So each refresh writes a new row version,
adds entries to *both* indexes, and leaves a dead tuple behind. That is
why the storage parameters above tighten autovacuum — a hot-key cache
produces dead tuples far faster than the cluster defaults expect.

If your workload is dominated by refreshing a small set of hot keys,
consider the **index-free variant**: drop `cache_expires_at_idx` so
`expires_at` is no longer indexed, making refreshes HOT-eligible (`key`
never changes and `value`/`expires_at` are then unindexed). The sweep
becomes a sequential scan, which is a fine trade while the table stays
small — tens of MB. Measure before switching; don't guess.

**Invalidation is best-effort.** The cache is a different database, so a
cache write cannot be in the same transaction as the application write
it reflects. A commit to `<app>` followed by a failed `DELETE` on
`<app>_cache` leaves a stale entry. Prefer short TTLs as the backstop
and treat explicit invalidation as an optimisation, not a guarantee.

**No built-in stampede protection.** Nothing here coordinates concurrent
misses on the same key. `INSERT ... ON CONFLICT DO NOTHING` can be used
to claim a slot, or `pg_advisory_xact_lock(hashtext($1))` to serialise
recomputation per key.

**Keep values small.** `jsonb` over a few KB goes to TOAST, so each read
becomes multiple heap fetches plus decompression — at which point the
cache can cost more than the query it replaces.

---

## When this is the wrong tool

A Postgres cache wins on **operational simplicity**: no extra service to
run, back up, monitor or secure; the same connection string, roles and
observability as everything else; and cached values are readable in the
same SQL session as developer queries.

Reach for Redis/Valkey instead when you need sustained write rates in
the tens of thousands per second, a working set measured in many GB,
built-in eviction policies (this table has no LRU — it grows until the
sweep runs), native TTL on structures beyond key/value, or pub/sub. The
honest threshold is workload-specific; measure the sweep's cost and
`pg_total_relation_size('cache')` under real traffic before concluding
either way.
