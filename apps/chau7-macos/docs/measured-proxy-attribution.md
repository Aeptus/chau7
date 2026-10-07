# Measured proxy run attribution

The Go proxy stores a generated request ID with analytics and sends the same ID,
tab/session/project identity, request-start timestamp, cost and optional cache
counters over IPC. The Swift evidence key uses that stable ID, so redelivery is
idempotent and identical calls in one second remain distinct. Legacy messages keep
their historical key; old collapsed requests cannot be separated without evidence.

TelemetryStore owns all reconciliation on its serial queue. The existing Core
matcher requires provider/time agreement and every supplied identity to agree with
one run. Time windows include the start and exclude the end. Overlapping matches
remain unassigned. New run/session identities, live/final updates and retained
backfill re-evaluate attribution. Independent metrics are retained as a baseline
and restored if a new overlap revokes an earlier match. Derived measured run
summaries are projections and are excluded from evidence totals.

Run queries expose measurement_coverage with attributed/priced request counts.
Measured requests have proxy/observed provenance, but run states remain partial:
interception cannot prove that all run activity was observed. Missing/estimated
usage remains separately labelled. Cache creation is unavailable for providers
that expose only reads; absent counters remain nil and reported zero remains zero.
No missing historical counter is inferred. Provider pricing uses the existing
cache-tier calculation; retained evidence already includes its observed cost.

Reconciliation fails closed beyond 500 overlapping runs or 5000 retained requests
in a window. Startup backfill visits at most 500 recent runs and runs after startup
on the existing maintenance queue. It only joins retained usage evidence, never
queries an unrelated user database or reconstructs measurements from token estimates.
The new baseline table cascades with run retention. Tests use disposable stores,
synthetic IPC payloads and a local fake-provider/socket fixture.

Proxy analytics normalize each request before SQL aggregation, using the shared
provider policy. Charts, provider/model summaries and repository/hourly/daily
metered totals therefore agree with canonical run counters. Recent calls retain
raw observations and distinguish SQL NULL from a reported zero; their metered
usage normalizes cache/reasoning subsets without rewriting stored prices.
