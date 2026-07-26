# Roadmap

Planned work for the **Best By Year** Stremio addon. Features (enhancements)
and bugs/tech-debt are kept in separate sections below; a single file is enough
for a project this size.

## Planned improvements

### Cache the sorted per-year catalog (+ real pagination)
**Priority:** high · **Why:** the addon currently re-fetches every Cinemeta
page and re-sorts on *every* request, then returns the whole list at once
(`best_by_year` in `stremio-addon.rb`).

Cinemeta has no single query for "year filter + IMDB-rating sort" — confirmed
from its manifest: the `year` catalog is sorted by recency, and the
`imdbRating` catalog can only be filtered by film genre, not by year. So
fetch-all-then-resort is the only way to get the desired result from Cinemeta,
and the fix is to stop paying that cost on every request.

**Measured impact (2026-07-26, live app, one sample each).** Selecting a year
is slow and *highly variable* — the latency is dominated by Cinemeta's per-page
response time, not by our item count:

| Year | Movies | ~page-fetches (50/page) | End-to-end |
|------|--------|-------------------------|------------|
| 1985 | 232 | ~5 | 10.2s *(incl. cold start)* |
| 1995 | 342 | ~7 | 11.6s |
| 2005 | 621 | ~13 | 75.3s |
| 2015 | — | — | **>90s (timed out)** |
| 2024 | 712 | ~15 | 28.8s |

Takeaways:
- Latency does **not** track item count (2005 with 621 items took 75s; 2024
  with 712 took 29s) — the variance is upstream Cinemeta latency amplified by
  sequential paging.
- Some years already exceed ~90s, which almost certainly exceeds Stremio's
  client patience → the catalog appears to fail to load. This is a real,
  present bug for slow years, independent of the year range offered.

Approach:
- Cache the sorted array keyed by `(type, year)`.
- TTL by year: past years are effectively immutable (cache ~indefinitely);
  the current year gains titles over time (short TTL, e.g. a few hours).
- Honor the `skip` param and slice the cached array into real pages instead of
  returning every item in one response.

Keeps IMDB ratings and Cinemeta `tt` ids unchanged — no behavioural change for
users, just faster and lighter.

### Optionally widen the year range (safe, low value without caching)
The manifest currently offers a rolling 20-year window
(`(current_year - 20)..current_year`). Extending it back into the 90s/80s is
**performance-safe**: the dropdown length is free (manifest is built per
request, trivially), and older years are the *smallest* catalogs (1985 ≈ 232
movies vs 2024 ≈ 712), so they fetch faster than recent years. Worst case stays
the recent years already served. Do this only alongside the caching work above —
otherwise it just adds more slow-to-load years.

## Ideas / alternatives considered

### TMDB Discover API as the data source
`GET /discover/movie?primary_release_year=YYYY&sort_by=vote_average.desc&vote_count.gte=N&page=P`
does year-filter + rating-sort + pagination natively, server-side, with no full
fetch. Not chosen for now because of the trade-offs:
- Requires a (free) TMDB API key.
- Ratings become TMDB vote averages, **not IMDB** (needs `vote_count.gte` to
  avoid single-vote outliers topping the list).
- TMDB returns tmdb ids; Stremio/Cinemeta render meta from IMDB `tt` ids, so it
  needs an id mapping (extra `/external_ids` call per item, reintroducing
  fan-out) or a switch to TMDB-native meta.

Revisit only if true server-side pagination is needed and TMDB ratings are
acceptable.

## Known issues / tech debt

- **Manifest `version` is frozen at `2.0.0`** — Stremio may serve a cached
  addon when the version doesn't change. Bump the version on user-visible
  changes so clients pick up updates without a manual remove/re-add.
