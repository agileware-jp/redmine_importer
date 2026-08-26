## Performance: Eliminate N+1 queries for reference masters

The per-row lookups of reference masters (Project / Tracker / IssueStatus /
Enumeration / IssueCategory) in `ImporterController#result` — previously run for
every CSV row via `find_by_name` / `find_by_project_id_and_name` — are now
bulk-loaded once in `init_globals` and served from in-memory hashes, eliminating
the N+1.

### Benchmark

- **Tables measured**: projects, trackers, issue_statuses, enumerations, issue_categories
- **BEFORE** = per-row `find_by_*` (old code / N+1) — **AFTER** = bulk load + hash lookup
- Query counts exclude cache hits and SCHEMA queries; measured with the AR query
  cache disabled (`uncached`)
- Environment: Redmine 6.0.5.stable / PostgreSQL

| rows | before queries | after queries | queries reduced | before ms | after ms | time reduced |
|-----:|---------------:|--------------:|----------------:|----------:|---------:|-------------:|
|   50 |            250 |             5 |          -98.0% |      42.1 |      1.7 |       -95.9% |
|  200 |           1000 |             5 |          -99.5% |     143.7 |      1.7 |       -98.8% |
| 1000 |           5000 |             5 |          -99.9% |     617.8 |      2.1 |       -99.7% |

- **before**: master queries grow linearly as `5 × N` (rows)
- **after**: constant **5 queries** regardless of row count (one bulk load per table)
- At 1000 rows: **5000 → 5 queries (-99.9%), 618ms → 2.1ms (-99.7%)**

> Note: a real import saves an issue on every row, which invalidates the
> ActiveRecord query cache each iteration. As a result the per-row `find_by_*`
> calls are never served from cache and always hit the DB (a genuine N+1). The
> benchmark therefore measures with the query cache disabled to stay faithful to
> the real behavior.

### How to reproduce

Run from the Redmine root (with this plugin installed at `plugins/redmine_importer`):

```bash
RAILS_ENV=development bundle exec rails runner \
  plugins/redmine_importer/test/benchmark/reference_master_lookup_benchmark.rb
```
