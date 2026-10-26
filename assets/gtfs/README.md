# Chennai GTFS feed — Chennai Metro (CMRL) data-quality history

`chennai-unified-gtfs.zip` in this folder imports successfully for the
bus network (MTC, agency_id `69`). As of Phase D (transit
network/route-quality phase), **Chennai Metro (CMRL) trips now import
and are honestly considered by journey planning** — the two structural
malformations described below have been fixed at the feed level, not
worked around in code. However, a separate, deeper limitation in the
same feed's CMRL *schedule data itself* (not a structural bug — see
"Known remaining limitation" below) means metro is rarely the
best-ranked option today. This is reported honestly rather than
papered over.

## What was wrong, and how it was fixed

`GtfsImportService` validates strictly against each file's own header
(not positionally) — a row that doesn't match its header's declared
column count/order is rejected as invalid, not silently guessed at.
Two of the bundled feed's files had exactly this kind of malformed
CMRL data:

- **`routes.txt`** (fixed earlier, `bundledGtfsDataVersion`
  `-v1` → `-v2`): the 3 CMRL route rows (Blue Line, Green Line,
  Inter-Corridor) had 6 comma-separated fields against a header
  declaring 5 columns — `route_type` ended up misaligned and wasn't a
  valid integer. Corrected by reordering the 3 rows to match the
  header exactly.
- **`trips.txt`** (fixed in Phase D, `-v2` → `-v3`): 96 CMRL trip rows
  had 5 comma-separated fields against a header declaring 4 columns
  (`trip_id,route_id,service_id,direction_id`). The correct field
  order — `route_id, service_id, trip_id, direction_id, shape_id` —
  was proven, not guessed, by cross-referencing three independent
  sources: field 1 matches the 3 real CMRL `route_id`s in
  `routes.txt`; field 2 matches real `service_id`s in `calendar.txt`;
  field 3 appears verbatim as a `trip_id` in `stop_times.txt` with
  real stop-time rows. Corrected by reordering to
  `[trip_id, route_id, service_id, direction_id]` (matching the
  existing header exactly) and dropping the undeclared trailing
  `shape_id` field, which this feed's header never declared and this
  app's routing doesn't use.

  A separate, unrelated problem — 6 rows in `trips.txt` that are
  actually `calendar.txt`-shaped content (10 fields, including a
  literal script-injection payload) that leaked into the file — is
  **not** part of this fix and remains correctly rejected; it has
  nothing to do with CMRL and there's no provable correct
  reinterpretation of it.

Every metro-aware code path (`GtfsQueryService.getNearestMetroStation`,
`GtfsImportReport.hasChennaiMetroData`) was already written to report
its actual state honestly rather than assume success — no code changes
were needed there; they now simply report the true (working) state.

## Current status

All 3 CMRL routes (Blue Line, Green Line, Inter-Corridor) and their 96
trips import successfully and are structurally valid — real
`route_id`/`service_id`/`trip_id`/`direction_id` references, all
foreign keys resolve, `GtfsImportReport.hasChennaiMetroData` is `true`,
and `GtfsQueryService.getNearestMetroStation` returns real stations.
RAPTOR includes metro trips in every search exactly like bus trips —
nothing in the routing code special-cases or excludes them.

## Known remaining limitation (schedule data, not structural — found in Phase D)

Fixing the trips.txt column order exposed a second, separate problem
in this same bundled feed's `stop_times.txt`, which the earlier
"6 rejected rows" count never surfaced because the CMRL rows weren't
importing at all yet:

- **Only 2 `stop_times` rows exist per metro trip** — the first and
  last stop of the line. None of the 44 real CMRL stations in
  between (Anna Nagar, Egmore, Guindy, Koyambedu, etc.) has a
  `stop_times` row on any trip, so nobody can board or alight at them
  today. In practice this makes each line/direction usable only
  between one fixed pair of stations: Blue Line only between Wimco
  Nagar Depot ↔ Chennai International Airport, Green Line only
  between MGR Chennai Central ↔ St. Thomas Mount, Inter-Corridor only
  between MGR Chennai Central ↔ Chennai International Airport.
- **The schedule values themselves are round-hour placeholders, not a
  real timetable** — trips depart only at fixed clock hours
  (05:00/08:00/11:00/17:00/20:00/22:00, a 2-6 hour headway) and each
  trip's recorded travel time between its two stops is 1-8 hours
  (e.g. one Inter-Corridor trip is recorded as 11:00→17:00, a 6-hour
  "ride" between Central and the Airport). Real CMRL headways are
  minutes, not hours, and the real Inter-Corridor/Airport run takes
  under an hour.

Given this, journey ranking correctly and honestly prefers a direct
~55-minute bus over a metro option that (per the feed's own recorded
numbers) requires waiting up to several hours for the next departure
and then several more hours "in transit" — that is the ranking working
as intended on the data as given, not a bug. **Nothing in this app
invents better numbers to compensate** — per this feed's own stated
policy (see the "How to fix it" note below), guessing schedule data is
worse than honestly ranking metro low when its own recorded schedule
is this sparse.

This is why the trips.txt structural fix (proven correct by
cross-referencing three other files — see above) was still worth
making even though its real-world routing impact turned out to be
small: it replaced "metro literally cannot be considered" with "metro
is honestly considered and currently loses on the merits of its own
recorded schedule," which is the honest, non-fabricated outcome.

## How to fully fix it

Replace `chennai-unified-gtfs.zip`'s CMRL portion with a feed carrying
real per-station `stop_times` and real headways, e.g. from CUMTA's
official open-data portal (https://opendata.cumta.org/). This importer
is not hardcoded to any one feed's contents — it re-runs its full
header-driven validation against whatever zip is placed here, so a
feed with genuine per-station stop_times would import cleanly and
immediately start producing real multi-station metro journeys with no
code changes required.
